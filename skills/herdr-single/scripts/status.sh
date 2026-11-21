#!/usr/bin/env bash
# One-screen overview of a run: the run's subscription and its 5h window, how many more
# helpers the window can carry now, the lead, every session, and what still needs a
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
provider=$(run_provider "$run")
live=$(python3 -c '
import json, sys
s = json.load(open(sys.argv[1]))
print(sum(1 for k in ("workers", "reviewers") for r in s.get(k, []) if r.get("status") not in ("cleaned", "escalated", "promoted")))
' "$run/state.json")
quota line --provider "$provider" || true
mapfile -t sug < <(quota suggest --provider "$provider" --live "$live" 2>/dev/null || true)
echo "new helpers now: ${sug[0]:-?} (${sug[1]:-quota unavailable})"

python3 - "$run/state.json" "$me" <<'PY'
import json, os, sys
s, me = json.load(open(sys.argv[1])), sys.argv[2]
print(f"goal: {s.get('goal') or '-'}")
print(f"provider: {s.get('provider')} (single subscription)")
print(f"repo: {s['repo']}  commit_authorized={s.get('commit_authorized')} push_authorized={s.get('push_authorized')}")
run = os.path.dirname(sys.argv[1])
lead = json.load(open(os.path.join(run, "lead.json"))) if os.path.exists(os.path.join(run, "lead.json")) else {}
GONE = ("cleaned", "escalated", "promoted")
recs = [r for k in ("workers", "reviewers") for r in s.get(k, [])]
if lead:
    print(f"lead: {lead['name']} ({lead.get('model') or '?'}, pane {lead['pane']}, {lead.get('status')})"
          f"  panel: {lead.get('panel_pane') or 'none'}")
    if lead.get("status") == "parked":
        print(f"  parked: {lead.get('parked_reason') or 'window exhausted'}; resumes at the reset")
    if lead.get("history"):
        print("  previous: " + ", ".join(f"{h['name']} ({h['reason']})" for h in lead["history"]))
if me == "lead":
    print("you are the lead")
elif me == "outsider":
    print(f"you are NOT the lead of this run (your pane is {os.environ.get('HERDR_PANE_ID')}); see SKILL.md, Resume a run")
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
for r in recs:
    extra = ""
    if r.get("review_of"): extra += f" reviews={r['review_of']}"
    if r.get("base_from"): extra += f" base={r['base_from']}"
    if r.get("continues"): extra += f" continues={r['continues']}"
    integrated = os.path.exists(os.path.join(r.get("state_dir", ""), "integrated.sha"))
    print(f"  {r['name']:<16} {r.get('model') or '?':<18} {r['role']:<11} {r.get('status', '?'):<20} "
          f"fix={r.get('fix_rounds', 0)} pane={r.get('pane') or '-'}{' integrated' if integrated else ''}{extra}")
todo = []
for r in live:
    st = r.get("status")
    if st in ("needs_approval", "blocked"): todo.append(f"{r['name']}: {st}, needs the user")
    elif st in ("settled_no_report", "timeout_or_stalled"): todo.append(f"{r['name']}: {st}, see references/recovery.md")
    elif st == "settled" and r["role"] == "reviewer": todo.append(f"{r['name']}: reviewer settled; close it unless a follow-up round is planned")
    elif st == "dispatched": todo.append(f"{r['name']}: dispatched; if no dispatch of yours is waiting on it, collect it: dispatch.sh --collect")
for t in todo:
    print("todo: " + t)
alerts = os.path.join(run, "alerts.log")
if os.path.exists(alerts) and os.path.getsize(alerts):
    print("alerts:")
    print("".join("  " + l for l in open(alerts).readlines()[-5:]), end="")
PY
