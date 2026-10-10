#!/usr/bin/env bash
# Pass the lead role of a run to a fresh session of the other provider, for example
# when the lead runs out of quota. The panel calls it automatically; the lead may call
# it itself at a safe point when the panel warned that its quota is low.
# The previous lead's pane is left open and never typed into; the lead fence in
# common.sh stops it from acting on the run if it wakes up again.
#
# Usage: handoff.sh --run DIR --reason TEXT [--to codex|claude]   start a successor lead
#        handoff.sh --run DIR --deliver     send the resume prompt once the successor is ready
#        handoff.sh --run DIR --adopt       make the calling pane the lead (manual takeover)
# Exit: 0 done or waiting for approval, 3 handoff disabled, 4 no provider with quota left.
set -euo pipefail
here=$(dirname "$(realpath "$0")")
. "$here/common.sh"
skill_dir=$(dirname "$here")

run=""; reason=""; to=""; mode=handoff
while [ $# -gt 0 ]; do
  case "$1" in
    --run) run=$2; shift 2 ;;
    --reason) reason=$2; shift 2 ;;
    --to) to=$2; shift 2 ;;
    --deliver) mode=deliver; shift ;;
    --adopt) mode=adopt; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -f "$run/state.json" ] || die "no state.json in '$run'"
run=$(realpath "$run")
lj="$run/lead.json"
[ -f "$lj" ] || die "no lead.json in $run (run-init records the lead when it starts inside a Herdr pane)"

lead_update() {
  python3 - "$lj" "$1" "${@:2}" <<'PY'
import datetime, json, os, sys
path, code, args = sys.argv[1], sys.argv[2], sys.argv[3:]
lead = json.load(open(path))
now = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")
exec(code, {"lead": lead, "args": args, "now": now})
with open(path + ".tmp", "w") as f:
    json.dump(lead, f, indent=2)
os.replace(path + ".tmp", path)
PY
}

if [ "$mode" = deliver ]; then
  [ "$(json_get "$lj" status)" = awaiting_approval ] || exit 0
  mkdir "$run/deliver.lock" 2>/dev/null || exit 0
  trap 'rmdir "$run/deliver.lock" 2>/dev/null || true' EXIT
  pane=$(json_get "$lj" pane); name=$(json_get "$lj" name)
  [ -z "$(pane_dialog "$pane")" ] || { echo "successor $name still shows a dialog in pane $pane"; exit 0; }
  st=$(agent_status "$pane")
  [ "$st" = idle ] || [ "$st" = "done" ] || { echo "successor $name is $st; waiting"; exit 0; }
  # /goal starts a turn itself. Its text points at the full resume instructions,
  # so a verified restore is already the resume submission, not an extra turn.
  restored=$(python3 "$here/goal-handoff.py" restore --run "$run" --pane "$pane")
  [ "$restored" != defer ] || { echo "successor became busy; delivery deferred"; exit 0; }
  if [ "$restored" != started ]; then
    [ -z "$(pane_dialog "$pane")" ] || { echo "successor shows a dialog; delivery deferred"; exit 0; }
    herdr agent prompt "$pane" "$(json_get "$lj" pending_prompt)" >/dev/null
  fi
  echo "goal transfer: $restored (details: $run/goal-transfer.json)"
  lead_update 'lead["status"] = "active"; lead.pop("pending_prompt", None)'
  echo "resume prompt delivered to $name (pane $pane)"
  exit 0
fi

if [ "$mode" = adopt ]; then
  me=${HERDR_PANE_ID:-}
  [ -n "$me" ] || die "--adopt must run inside the Herdr pane that becomes the lead"
  if [ "$me" = "$(json_get "$lj" pane)" ]; then
    echo "this pane ($me) is already the lead of $run; nothing to adopt"
    exit 0
  fi
  kind=$(herdr agent get "$me" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["agent"].get("agent") or "")' 2>/dev/null || true)
  lead_update '
lead.setdefault("history", []).append({k: lead.get(k) for k in ("name", "pane", "kind")} | {"ended_at": now, "reason": "adopted by another pane"})
lead.update(pane=args[0], kind=args[1] or None, name="lead" + str(lead.get("generation", 1) + 1),
            generation=lead.get("generation", 1) + 1, status="active")
' "$me" "$kind"
  rm -f "$run/lead.warning"
  echo "this pane ($me) is now the lead of $run"
  exit 0
fi

[ -n "$reason" ] || die "--reason is required"
require_lead "$run"
mkdir "$run/handoff.lock" 2>/dev/null || die "a handoff is already in progress ($run/handoff.lock)"
trap 'rmdir "$run/handoff.lock" 2>/dev/null || true' EXIT

cur_kind=$(json_get "$lj" kind)
target=${to:-$HERDR_DUO_LEAD_FALLBACK}
case "$target" in
  off) echo "lead handoff is disabled (HERDR_DUO_LEAD_FALLBACK=off): $reason"; exit 3 ;;
  auto)
    case "$cur_kind" in
      claude) target=codex ;; codex) target=claude ;;
      *) echo "cannot choose a successor: the lead's provider is unknown. Set HERDR_DUO_LEAD_FALLBACK=codex|claude"; exit 3 ;;
    esac ;;
  codex|claude) ;;
  *) die "--to / HERDR_DUO_LEAD_FALLBACK must be auto, codex, claude or off" ;;
esac

# A provider whose lead already ran out in this run is not tried again for 5 hours.
recent=$(python3 - "$lj" "$target" <<'PY'
import datetime, json, sys
lead, target = json.load(open(sys.argv[1])), sys.argv[2]
at = lead.get("exhausted", {}).get(target)
if at and datetime.datetime.now(datetime.timezone.utc) - datetime.datetime.fromisoformat(at) < datetime.timedelta(hours=5):
    print(at)
PY
)
if [ -n "$recent" ]; then
  lead_update 'lead["status"] = "stranded"; lead["stranded_reason"] = args[0]' "$reason"
  echo "NO SUCCESSOR: $target already ran out of quota in this run at $recent. The run waits; resume it manually later (SKILL.md, Resume a run)."
  exit 4
fi

old_pane=$(json_get "$lj" pane); old_name=$(json_get "$lj" name)
gen=$(json_get "$lj" generation); gen=$((${gen:-1} + 1))
name="lead$gen"
repo=$(json_get "$run/state.json" repo)
# Read only the old leader's session. No input is sent to that pane, even when
# quota is exhausted or a command is still running there.
python3 "$here/goal-handoff.py" capture --run "$run" --pane "$old_pane" >/dev/null

if [ "$target" = codex ]; then
  args=(-m "$HERDR_DUO_LEAD_CODEX_MODEL" -c "model_reasoning_effort=$HERDR_DUO_LEAD_CODEX_EFFORT")
  grep -q -- '--no-daemon' <<<"$(codex --help 2>&1 || true)" && args+=(--no-daemon)
  # The successor runs unattended, so it cannot stop at approval prompts.
  if [ "$HERDR_DUO_LUNA_ACCESS" = full ]; then args+=(-s danger-full-access -a never); else args+=(-s workspace-write -a on-request); fi
else
  args=(--model "$HERDR_DUO_LEAD_CLAUDE_MODEL" --add-dir "$HERDR_DUO_STATE_ROOT" --add-dir "$skill_dir" --permission-mode "$HERDR_DUO_HAIKU_MODE")
fi
for a in "${args[@]}"; do
  [[ "$a" =~ ^[A-Za-z0-9_./,=:@+-]+$ ]] || die "argument not shell-safe for herdr agent start: '$a'"
done

split_out=""
for from in "$old_pane" "$(json_get "$lj" panel_pane)"; do
  [ -n "$from" ] || continue
  split_out=$(herdr pane split "$from" --direction down --cwd "$repo" --no-focus 2>/dev/null) && break
  split_out=""
done
[ -n "$split_out" ] || split_out=$(herdr pane split --current --direction down --cwd "$repo" --no-focus)
pane=$(printf %s "$split_out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["pane"]["pane_id"])') \
  || die "could not read pane id from: $split_out"
herdr agent start "$name" --kind "$target" --pane "$pane" --timeout 90000 -- "${args[@]}" >/dev/null 2>&1 || true

prompt="Use the herdr-duo skill to resume the run at $run as its new lead (skill directory: $skill_dir). The previous lead $old_name stopped: $reason. Start with the section 'Resume a run' in SKILL.md and execute it now. Inherit the original task and recorded user authorization; do not ask whether to continue. Read goal-native.json, goal-transfer.json if present, state.json, progress.json and goal.json. Respect paused, blocked, completed or budget-exhausted goal state; never reactivate it automatically. A native usage_limited goal may continue on the other provider as the skill describes. If goal-transfer.json says needs_budget_tool, use your native goal tool to restore the objective with only the known remaining token budget before starting work; never create an unlimited replacement. For an unavailable native reader/command, recover the portable goal as the skill permits and report the limitation without blocking authorized work. Inspect and collect every already-running owned worker/process without duplicating it, then continue all unfinished steps through validation and authorized delivery/cleanup. Do not stop after a status update or dispatch. Only a genuinely unresolved required user decision or actual approval dialog blocks dependent work; keep making independent progress."
printf '%s\n' "$prompt" > "$run/lead-resume.md"
lead_update '
old = {k: lead.get(k) for k in ("name", "pane", "kind")}
lead.setdefault("history", []).append(old | {"ended_at": now, "reason": args[4]})
if old["kind"]:
    lead.setdefault("exhausted", {})[old["kind"]] = now
lead.update(name=args[0], pane=args[1], kind=args[2], generation=int(args[3]),
            status="awaiting_approval", pending_prompt=args[5])
lead.pop("stranded_reason", None)
' "$name" "$pane" "$target" "$gen" "$reason" "$prompt"
rm -f "$run/lead.warning"

echo "HANDOFF: $old_name ($old_pane) -> $name ($target, pane $pane): $reason"
echo "The previous lead's pane stays open. If you are the previous lead: stop now and do nothing more in this run."
dialog=$(pane_dialog "$pane")
if [ -n "$dialog" ]; then
  echo "successor shows a startup dialog: \"$dialog\". The user answers it in pane $pane; the panel then delivers the resume prompt."
  exit 0
fi
"$here/handoff.sh" --run "$run" --deliver
