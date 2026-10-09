#!/usr/bin/env bash
# Escalate a base implementer (Luna / Haiku) to a fresh strong session (Sol / Sonnet).
# The strong session continues in the same worktree and state dir, so the failed
# attempt stays visible and baseline, delta and integration history carry over.
# The base session's pane is closed; it is not reused.
#
# Usage: escalate.sh --run DIR --name NAME --reason TEXT [--provider codex|claude]
#                    [--cross-cutting] [--split-from PANE_ID] [--direction right|down]
#   --provider       default: the provider that did not fail (a different model family)
#   --cross-cutting  escalate before two failed rounds, because the task turned out to
#                    need cross-file reasoning (state the evidence in --reason)
# Refuses when: NAME is not a settled base implementer, fewer than two failed rounds
# were recorded (initial round plus one dispatch.sh --fix) without --cross-cutting,
# or another strong session is still live.
set -euo pipefail
here=$(dirname "$(realpath "$0")")
. "$here/common.sh"

run=""; name=""; reason=""; provider=""; cross=no; split_args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --run) run=$2; shift 2 ;;
    --name) name=$2; shift 2 ;;
    --reason) reason=$2; shift 2 ;;
    --provider) provider=$2; shift 2 ;;
    --cross-cutting) cross=yes; shift ;;
    --split-from|--direction) split_args+=("$1" "$2"); shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -f "$run/state.json" ] || die "no state.json in '$run'"
run=$(realpath "$run")
[ -n "$name" ] && [ -n "$reason" ] || die "--name and --reason are required"

role=$(record_get "$run" "$name" role)
[ "$role" = implementer ] || die "'$name' is not an implementer in this run"
tier=$(record_get "$run" "$name" tier)
[ "${tier:-base}" = base ] || die "'$name' is already strong; strong sessions do not escalate further. Report the blocker"
status=$(record_get "$run" "$name" status)
case "$status" in
  cleaned|escalated) die "'$name' is $status" ;;
  dispatched) die "'$name' is still working; wait for dispatch.sh to return" ;;
esac
[ "$(agent_status "$name")" != working ] || die "'$name' is still working; wait for it to settle"

fix_rounds=$(record_get "$run" "$name" fix_rounds)
if [ "${fix_rounds:-0}" -lt 1 ] && [ "$cross" = no ]; then
  die "'$name' has no failed fix round yet. Escalation needs two failed rounds (send one with dispatch.sh --fix), or --cross-cutting with evidence"
fi
busy=$(live_strong "$run")
[ -z "$busy" ] || die "strong session '$busy' is still live; finish and clean it up first (strong sessions never run in parallel)"

failed_provider=$(record_get "$run" "$name" provider)
if [ -z "$provider" ]; then
  if [ "$failed_provider" = codex ]; then provider=claude; else provider=codex; fi
fi
case "$provider" in codex) suffix=sol ;; claude) suffix=sonnet ;; *) die "--provider must be codex or claude" ;; esac

sdir=$(record_get "$run" "$name" state_dir)
attempt="$sdir/attempt-$name.patch"
"$here/delta.sh" --state "$sdir" --out "$attempt" >/dev/null
echo "saved failed attempt of $name: $attempt ($(wc -l < "$attempt") lines)"

new="$name-$suffix"
n=2
while [ -n "$(record_get "$run" "$new" name)" ]; do new="$name-$suffix$n"; n=$((n + 1)); done

pane=$(record_get "$run" "$name" pane)
if [ -n "$pane" ]; then
  herdr pane close "$pane" >/dev/null 2>&1 && echo "closed $name (pane $pane)" || echo "pane $pane already gone"
fi
set_field "$run" "$name" status escalated
state_edit "$run" '
import datetime
state.setdefault("escalations", []).append({"from": args[0], "to": args[1], "reason": args[2],
    "cross_cutting": args[3] == "yes", "fix_rounds": int(args[4] or 0), "attempt_patch": args[5],
    "at": datetime.datetime.now(datetime.timezone.utc).isoformat()})
' "$name" "$new" "$reason" "$cross" "${fix_rounds:-0}" "$attempt"

"$here/spawn.sh" --run "$run" --name "$new" --provider "$provider" --role implementer \
  --tier strong --continue-from "$name" "${split_args[@]+"${split_args[@]}"}"

cat <<EOF
ESCALATED $name -> $new ($provider, strong tier)
next: write $run/$new/assignment.md from the escalation template in references/assignments.md
      (narrow scope; cite $run/$name/assignment.md and $attempt), then dispatch.sh --run $run --name $new
delta and integration use --state $sdir; close $new with cleanup.sh as soon as its delta is integrated
EOF
