#!/usr/bin/env bash
# Send a session its assignment file, wait until it settles, and print its final
# report. Run it as a background command: its completion notification already
# carries the report, so the lead spends no turn polling or reading transcripts.
#
# Usage: dispatch.sh --run DIR --name NAME [--timeout-min 30] [--message TEXT]
#   --message  follow-up instead of the initial pointer (fix rounds, report repeats)
# Exit: 0 settled with a report, 5 settled without a report, 6 blocked,
#       7 timeout or stalled (the prompt may still have been delivered), 2 usage error.
set -euo pipefail
. "$(dirname "$(realpath "$0")")/common.sh"

run=""; name=""; timeout_min=30; message=""
while [ $# -gt 0 ]; do
  case "$1" in
    --run) run=$2; shift 2 ;;
    --name) name=$2; shift 2 ;;
    --timeout-min) timeout_min=$2; shift 2 ;;
    --message) message=$2; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -f "$run/state.json" ] || die "no state.json in '$run'"
run=$(realpath "$run")
assignment="$run/$name/assignment.md"
if [ -z "$message" ]; then
  [ -f "$assignment" ] || die "missing $assignment; write it before dispatching"
  message="Read the assignment at $assignment and complete it. End with the final report block it defines."
fi

set_status() {
  python3 - "$run/state.json" "$name" "$1" <<'PY'
import json, sys
path, name, status = sys.argv[1:]
state = json.load(open(path))
for key in ("workers", "reviewers"):
    for r in state.get(key, []):
        if r.get("name") == name:
            r["status"] = status
json.dump(state, open(path, "w"), indent=2)
PY
}

pane=$(python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); print(next((r["pane"] for k in ("workers","reviewers") for r in s.get(k,[]) if r["name"]==sys.argv[2]), ""))' "$run/state.json" "$name")
[ -n "$pane" ] || die "no recorded session named $name in this run"
# Never type into a dialog: the Enter of a prompt would answer it.
dialog=$(pane_dialog "$pane")
if [ -n "$dialog" ]; then
  set_status needs_approval
  echo "== $name: NOT SENT, pane $pane shows a dialog: \"$dialog\". Ask the user to answer it, then retry." >&2
  exit 6
fi

set_status dispatched
rc=0
out=$(herdr agent prompt "$name" "$message" --wait --timeout $((timeout_min * 60000)) 2>&1) || rc=$?

agent_state=$(agent_status "$name")

report=$(herdr agent read "$name" --source recent-unwrapped --lines 150 2>/dev/null | python3 -c '
import sys
lines = sys.stdin.read().splitlines()
# Last real report; template lines such as "STATUS: done | blocked | failed" are skipped.
idx = max((i for i, l in enumerate(lines) if l.strip().startswith("STATUS:") and "|" not in l), default=None)
print("\n".join(lines[idx:idx + 40]) if idx is not None else "")
')

code=0
if [ "$rc" -ne 0 ]; then
  case "$out" in
    *agent_blocked*) code=6; set_status blocked ;;
    *) code=7; set_status timeout_or_stalled ;;
  esac
elif [ "$agent_state" = blocked ]; then
  code=6; set_status blocked
elif [ -z "$report" ]; then
  code=5; set_status settled_no_report
else
  set_status settled
fi

echo "== $name: state=${agent_state:-unknown} prompt_rc=$rc exit=$code"
[ "$rc" -eq 0 ] || echo "prompt: $(printf %s "$out" | tr '\n' ' ' | cut -c1-300)"
if [ -n "$report" ]; then
  printf '%s\n' "$report"
else
  echo "(no final report found; inspect: herdr agent read $name --source recent-unwrapped --lines 120)"
fi
exit $code
