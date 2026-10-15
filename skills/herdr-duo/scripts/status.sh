#!/usr/bin/env bash
# One-screen overview of a run: both leads, both subscriptions' 5h quota and the suggested
# provider for new helper work, every session grouped by owner, and what still needs a
# decision. Read-only.
#
# Usage: status.sh --run DIR
set -euo pipefail
. "$(dirname "$(realpath "$0")")/common.sh"

run=""
while [ $# -gt 0 ]; do
  case "$1" in
    --run) run=$2; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -f "$run/state.json" ] || die "no state.json in '$run'"
run=$(realpath "$run")
me=$(member "$run")
quota line || true
mine=$( [ -f "$run/lead.json" ] && json_get "$run/lead.json" kind || true)
if [ "$me" != lead ] && [ "$me" != panel ] && [ "$me" != outsider ]; then mine=$(record_get "$run" "$me" provider); fi
mapfile -t sug < <(quota suggest --for helper ${mine:+--mine "$mine"} 2>/dev/null || true)
echo "helpers now: ${sug[0]:-unknown} (${sug[1]:-})"

python3 - "$run/state.json" "$me" <<'PY'
import json, os, sys
s, me = json.load(open(sys.argv[1])), sys.argv[2]
print(f"goal: {s.get('goal') or '-'}")
print(f"repo: {s['repo']}  commit_authorized={s.get('commit_authorized')} push_authorized={s.get('push_authorized')}")
run = os.path.dirname(sys.argv[1])
lead = json.load(open(os.path.join(run, "lead.json"))) if os.path.exists(os.path.join(run, "lead.json")) else {}
GONE = ("cleaned", "escalated", "promoted")
recs = [r for k in ("workers", "reviewers") for r in s.get(k, [])]
sib = next((r for r in recs if r.get("level") == "sibling" and r.get("status") not in GONE), None)
if lead:
    print(f"principal: {lead['name']} ({lead.get('kind') or '?'} {lead.get('model') or '?'}, pane {lead['pane']}, {lead.get('status')})"
          f"  panel: {lead.get('panel_pane') or 'none'}")
    if lead.get("history"):
        print("  previous: " + ", ".join(f"{h['name']} ({h.get('kind')}: {h['reason']})" for h in lead["history"]))
print(f"sibling: {sib['name']} ({sib['provider']} {sib.get('model')}, pane {sib.get('pane')}, {sib.get('status')})" if sib else "sibling: none")
if me == "lead":
    print("you are the principal")
elif me == "outsider":
    print(f"you are NOT a lead of this run (your pane is {os.environ.get('HERDR_PANE_ID')}); see SKILL.md, Resume a run")
elif me != "panel":
    print(f"you are the sibling '{me}': act on your slice and your own helpers; report to the principal")
prog = json.load(open(os.path.join(run, "progress.json"))) if os.path.exists(os.path.join(run, "progress.json")) else {}
steps = prog.get("steps", [])
if steps:
    print(f"progress: {sum(1 for x in steps if x['status'] == 'done')}/{len(steps)} done; now: {prog.get('now') or '-'}")
    for i, x in enumerate(steps, 1):
        if x["status"] != "done":
            print(f"  {i}. [{x['status']}] {x['title']}")
for c in prog.get("checks", [])[-4:]:
    print(f"check: {c['label']} exit={c['rc']} {c['summary']} ({c['at']})")
if os.path.exists(os.path.join(run, "handoff.md")):
    print(f"handoff notes: {os.path.join(run, 'handoff.md')}")
live = [r for r in recs if r.get("status") not in GONE]
print(f"sessions: {len(live)} live, {len(recs) - len(live)} closed")
owners = ["lead"] + [r["name"] for r in recs if r.get("level") == "sibling"]
for owner in owners + sorted({r.get("owner", "lead") for r in recs} - set(owners)):
    mine = [r for r in recs if r.get("owner", "lead") == owner and r["name"] != owner]
    if not mine:
        continue
    print(f"  owned by {owner}:")
    for r in mine:
        extra = ""
        if r.get("review_of"): extra += f" reviews={r['review_of']}"
        if r.get("base_from"): extra += f" base={r['base_from']}"
        if r.get("continues"): extra += f" continues={r['continues']}"
        integrated = os.path.exists(os.path.join(r.get("state_dir", ""), "integrated.sha"))
        print(f"    {r['name']:<16} {r['provider']:<6} {r.get('model') or r.get('tier', '?'):<18} {r.get('level', 'helper'):<7} "
              f"{r['role']:<11} {r.get('status', '?'):<20} fix={r.get('fix_rounds', 0)} pane={r.get('pane') or '-'}"
              f"{' integrated' if integrated else ''}{extra}")
todo = []
for r in live:
    st, who = r.get("status"), r.get("owner", "lead")
    if st in ("needs_approval", "blocked"): todo.append(f"{r['name']} ({who}): {st}, needs the user")
    elif st in ("settled_no_report", "timeout_or_stalled"): todo.append(f"{r['name']} ({who}): {st}, see references/recovery.md")
    elif st == "settled" and r["role"] == "reviewer": todo.append(f"{r['name']} ({who}): reviewer settled; close it unless a follow-up round is planned")
    elif st == "dispatched": todo.append(f"{r['name']} ({who}): dispatched; if no dispatch of yours is waiting on it, collect it: dispatch.sh --collect")
for t in todo:
    print("todo: " + t)
alerts = os.path.join(run, "alerts.log")
if os.path.exists(alerts) and os.path.getsize(alerts):
    print("alerts:")
    print("".join("  " + l for l in open(alerts).readlines()[-5:]), end="")
PY
