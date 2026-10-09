#!/usr/bin/env bash
# One-screen overview of a run: every session with tier, status and fix rounds, the
# live strong session, escalations, and what still needs a decision. Read-only.
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

python3 - "$run/state.json" <<'PY'
import json, os, sys
s = json.load(open(sys.argv[1]))
print(f"goal: {s.get('goal') or '-'}")
print(f"repo: {s['repo']}  commit_authorized={s.get('commit_authorized')} push_authorized={s.get('push_authorized')}")
recs = [r for k in ("workers", "reviewers") for r in s.get(k, [])]
live = [r for r in recs if r.get("status") not in ("cleaned", "escalated")]
print(f"sessions: {len(live)} live, {len(recs) - len(live)} closed")
for r in recs:
    extra = ""
    if r.get("review_of"): extra += f" reviews={r['review_of']}"
    if r.get("continues"): extra += f" continues={r['continues']}"
    integrated = os.path.exists(os.path.join(r.get("state_dir", ""), "integrated.sha"))
    print(f"  {r['name']:<16} {r['provider']:<6} {r.get('tier', 'base'):<6} {r['role']:<11} "
          f"{r.get('status', '?'):<20} fix_rounds={r.get('fix_rounds', 0)} pane={r.get('pane') or '-'}"
          f"{' integrated' if integrated else ''}{extra}")
strong = [r["name"] for r in live if r.get("tier") == "strong"]
print(f"live strong session: {strong[0] if strong else 'none'}")
for e in s.get("escalations", []):
    print(f"escalation: {e['from']} -> {e['to']} ({'cross-cutting' if e.get('cross_cutting') else str(e.get('fix_rounds', 0) + 1) + ' failed rounds'}): {e['reason']}")
todo = []
for r in live:
    st = r.get("status")
    if st in ("needs_approval", "blocked"): todo.append(f"{r['name']}: {st}, needs the user")
    elif st in ("settled_no_report", "timeout_or_stalled"): todo.append(f"{r['name']}: {st}, see references/recovery.md")
    elif st == "settled" and r.get("tier") == "strong": todo.append(f"{r['name']}: strong session settled; integrate and clean it up now")
    elif st == "settled" and r["role"] == "reviewer": todo.append(f"{r['name']}: reviewer settled; close it unless a follow-up round is planned")
for t in todo:
    print("todo: " + t)
PY
