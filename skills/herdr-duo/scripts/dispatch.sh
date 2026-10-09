#!/usr/bin/env bash
# Send a session its assignment file, wait until it settles, and print its final
# report. Run it as a background command: its completion notification already
# carries the report, so the lead spends no turn polling or reading transcripts.
#
# Usage: dispatch.sh --run DIR --name NAME [--timeout-min 30] [--message TEXT | --fix TEXT | --collect]
#   --message  follow-up instead of the initial pointer (report repeats, clarifications)
#   --fix      follow-up that rejects the previous round; counts toward escalation
#   --collect  send nothing: wait for a session that is already working and print its
#              report (after a lead handoff, for workers the previous lead dispatched)
#   The initial pointer (no --message/--fix) starts a new task and resets the fix count.
# Exit: 0 settled with a report, 5 settled without a report, 6 blocked,
#       7 timeout or stalled (the prompt may still have been delivered), 2 usage error.
set -euo pipefail
. "$(dirname "$(realpath "$0")")/common.sh"

run=""; name=""; timeout_min=30; message=""; fix=no; collect=no
while [ $# -gt 0 ]; do
  case "$1" in
    --run) run=$2; shift 2 ;;
    --name) name=$2; shift 2 ;;
    --timeout-min) timeout_min=$2; shift 2 ;;
    --message) message=$2; shift 2 ;;
    --fix) message=$2; fix=yes; shift 2 ;;
    --collect) collect=yes; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -f "$run/state.json" ] || die "no state.json in '$run'"
run=$(realpath "$run")
require_lead "$run"
assignment="$run/$name/assignment.md"
initial=no
if [ -z "$message" ] && [ "$collect" = no ]; then
  initial=yes
  [ -f "$assignment" ] || die "missing $assignment; write it before dispatching"
  message="Read the assignment at $assignment and complete it. End with the final report block it defines."
fi

set_status() { set_field "$run" "$name" status "$1"; }

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
[ "$collect" = yes ] || set_field "$run" "$name" dispatched_at "$(date +%s)"
fix_rounds=$(record_get "$run" "$name" fix_rounds)
fix_rounds=${fix_rounds:-0}
if [ "$initial" = yes ]; then fix_rounds=0; elif [ "$fix" = yes ]; then fix_rounds=$((fix_rounds + 1)); fi
set_field "$run" "$name" fix_rounds "$fix_rounds"
rc=0
if [ "$collect" = yes ]; then
  out=$(herdr agent wait "$name" --until idle --until "done" --until blocked --timeout $((timeout_min * 60000)) 2>&1) || rc=$?
else
  out=$(herdr agent prompt "$name" "$message" --wait --timeout $((timeout_min * 60000)) 2>&1) || rc=$?
fi

agent_state=$(agent_status "$name")

report=$(herdr agent read "$name" --source recent-unwrapped --lines 150 2>/dev/null | python3 "$(dirname "$(realpath "$0")")/extract-report.py")

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

tier=$(record_get "$run" "$name" tier)
echo "== $name: state=${agent_state:-unknown} prompt_rc=$rc exit=$code tier=${tier:-base} fix_rounds=$fix_rounds"
[ "$rc" -eq 0 ] || echo "prompt: $(printf %s "$out" | tr '\n' ' ' | cut -c1-300)"
if [ -n "$report" ]; then
  printf '%s\n' "$report"
else
  echo "(no final report found; inspect: herdr agent read $name --source recent-unwrapped --lines 120)"
fi
if [ "$fix_rounds" -ge 1 ] && [ "$code" -eq 0 ]; then
  if [ "${tier:-base}" = strong ]; then
    echo "note: if this fix round failed too, stop and report the blocker; strong sessions do not escalate further"
  else
    echo "note: if this fix round failed too, that is two failed rounds; escalate unless the work is mechanical (escalate.sh)"
  fi
fi
lead_warning "$run"
exit $code
