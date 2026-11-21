#!/usr/bin/env bash
# Lead continuity for a single-subscription run. There is no other subscription to hand
# the run to, so:
#   - When the lead's 5h window is out, the run is PARKED until the window resets. The
#     panel calls this automatically; the lead may call it itself at a safe point.
#   - When the window resets, the panel calls --resume: the same lead pane gets a resume
#     prompt if it is still alive (it keeps its context), otherwise a fresh lead of the
#     same provider starts below it (HERDR_SINGLE_LEAD_RESUME=fresh always starts one).
#   - A lead whose context is full, with quota left, calls this with a reason: a fresh lead
#     of the same provider starts now and resumes from the checkpoint.
# A replaced lead's pane is left open and never typed into; the lead fence in common.sh
# stops it from acting on the run if it wakes up again.
#
# Usage: handoff.sh --run DIR --reason TEXT [--lead-model MODEL]  park (window out) or fresh lead
#        handoff.sh --run DIR --reason TEXT --park  park even if the sensor shows quota (a limit
#                                                   message on the lead's screen); retried at the
#                                                   known reset, else in 30 minutes
#        handoff.sh --run DIR --resume        after the reset: resume in place or start fresh
#        handoff.sh --run DIR --deliver       send the resume prompt once the successor is ready
#        handoff.sh --run DIR --adopt         make the calling pane the lead (manual takeover)
# Exit: 0 done or waiting for the successor, 4 parked (no quota until the reset).
set -euo pipefail
here=$(dirname "$(realpath "$0")")
. "$here/common.sh"
skill_dir=$(dirname "$here")

run=""; reason=""; mode=handoff; lead_model=""; force_park=no
while [ $# -gt 0 ]; do
  case "$1" in
    --run) run=$2; shift 2 ;;
    --reason) reason=$2; shift 2 ;;
    --lead-model) lead_model=$2; shift 2 ;;
    --resume) mode=resume; shift ;;
    --park) force_park=yes; shift ;;
    --deliver) mode=deliver; shift ;;
    --adopt) mode=adopt; shift ;;
    --to) die "herdr-single never hands a run to another subscription" ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -f "$run/state.json" ] || die "no state.json in '$run'"
run=$(realpath "$run")
lj="$run/lead.json"
[ -f "$lj" ] || die "no lead.json in $run (run-init records the lead when it starts inside a Herdr pane)"
provider=$(run_provider "$run")
case "$provider" in codex|claude) ;; *) die "state.json records no provider" ;; esac

# Every lead.json writer (this script, run-init and the panel) holds lead.json.lock and
# re-reads the file under it, so concurrent updates never overwrite each other.
lead_update() {
  python3 - "$lj" "$1" "${@:2}" <<'PY'
import datetime, fcntl, json, os, sys, tempfile, time
path, code, args = sys.argv[1], sys.argv[2], sys.argv[3:]
with open(path + ".lock", "w") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    with open(path) as f:
        lead = json.load(f)
    now = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")
    exec(code, {"lead": lead, "args": args, "now": now, "time": time})
    with tempfile.NamedTemporaryFile("w", dir=os.path.dirname(path), prefix="lead-", suffix=".tmp", delete=False) as f:
        json.dump(lead, f, indent=2)
    os.replace(f.name, path)
PY
}

if [ "$mode" = deliver ]; then
  case "$(json_get "$lj" status)" in awaiting_approval|awaiting_delivery) ;; *) exit 0 ;; esac
  mkdir "$run/deliver.lock" 2>/dev/null || exit 0
  trap 'rmdir "$run/deliver.lock" 2>/dev/null || true' EXIT
  pane=$(json_get "$lj" pane); name=$(json_get "$lj" name)
  [ -z "$(pane_dialog "$pane")" ] || { echo "lead $name still shows a dialog in pane $pane"; exit 0; }
  st=$(agent_status "$pane")
  [ "$st" = idle ] || [ "$st" = "done" ] || { echo "lead $name is $st; waiting"; exit 0; }
  if [ -n "$(json_get "$lj" in_place)" ]; then
    # The same session continues: it keeps its own context and goal.
    herdr agent prompt "$pane" "$(json_get "$lj" pending_prompt)" >/dev/null
  else
    # /goal starts a turn itself. Its text points at the full resume instructions,
    # so a verified restore is already the resume submission, not an extra turn.
    restored=$(python3 "$here/goal-handoff.py" restore --run "$run" --pane "$pane")
    [ "$restored" != defer ] || { echo "successor became busy; delivery deferred"; exit 0; }
    if [ "$restored" != started ]; then
      [ -z "$(pane_dialog "$pane")" ] || { echo "successor shows a dialog; delivery deferred"; exit 0; }
      herdr agent prompt "$pane" "$(json_get "$lj" pending_prompt)" >/dev/null
    fi
    echo "goal transfer: $restored (details: $run/goal-transfer.json)"
  fi
  lead_update 'lead["status"] = "active"; lead.pop("pending_prompt", None); lead.pop("in_place", None)'
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
  [ -z "$kind" ] || [ "$kind" = "$provider" ] || die "this pane runs $kind; the run uses only $provider"
  adopted_model=$(lead_models detect --pane "$me")
  lead_update '
lead.setdefault("history", []).append({k: lead.get(k) for k in ("name", "pane", "model")} | {"ended_at": now, "reason": "adopted by another pane"})
lead.update(pane=args[0], name="lead" + str(lead.get("generation", 1) + 1),
            generation=lead.get("generation", 1) + 1, status="active", model=args[1] or None)
for k in ("parked_reason", "parked_until", "pending_prompt", "in_place"):
    lead.pop(k, None)
' "$me" "$adopted_model"
  rm -f "$run/lead.warning"
  echo "this pane ($me) is now the lead of $run"
  exit 0
fi

if [ "$mode" = handoff ]; then
  [ -n "$reason" ] || die "--reason is required"
  require_lead "$run"
fi
mkdir "$run/handoff.lock" 2>/dev/null || die "a handoff is already in progress ($run/handoff.lock)"
trap 'rmdir "$run/handoff.lock" 2>/dev/null || true' EXIT

if [ -n "$lead_model" ]; then
  [ -z "$(json_get "$lj" initial_model)" ] || die "the initial lead model is already recorded; --lead-model only fills a missing one"
  profile=$(lead_models init --pane "$(json_get "$lj" pane)" --provider "$provider" --model "$lead_model")
  lead_update 'lead.update(__import__("json").loads(args[0]))' "$profile"
fi

# The window now; unknown quota never parks a run.
qjson=$(quota json --provider "$provider" 2>/dev/null || echo '{}')
until_hm=$(python3 - "$provider" "$qjson" "$HERDR_SINGLE_LEAD_HANDOFF_PCT" "$force_park" <<'PY'
import json, sys, time
provider, q, pct, force = sys.argv[1], json.loads(sys.argv[2] or "{}"), float(sys.argv[3]), sys.argv[4] == "yes"
x = q.get(provider, {})
until = None
if x.get("known") and x["left"] <= pct:
    until = x.get("resets_at") or time.time() + 5 * 3600
elif force:
    # The screen says the limit is hit but the sensor disagrees: trust a future reset
    # time, else look again in 30 minutes.
    r = x.get("resets_at")
    until = r if r and r > time.time() else time.time() + 30 * 60
if until:
    print(int(until), time.strftime("%H:%M", time.localtime(until)))
PY
)

if [ -n "$until_hm" ]; then
  read -r until hm <<<"$until_hm"
  why=${reason:-"the 5h window is still out"}
  lead_update 'lead.update(status="parked", parked_reason=args[0], parked_until=int(args[1]))' "$why" "$until"
  echo "PARKED: the $provider 5h window is out until $hm ($why). The run keeps its state; the panel resumes it at the reset (SKILL.md, Resume a run). If you are the lead: checkpoint with progress.sh note and stop."
  exit 4
fi

old_pane=$(json_get "$lj" pane); old_name=$(json_get "$lj" name)

if [ "$mode" = resume ]; then
  [ "$(json_get "$lj" status)" = parked ] || { echo "the run is not parked; nothing to resume"; exit 0; }
  if [ "$HERDR_SINGLE_LEAD_RESUME" != fresh ] && [ -n "$(agent_status "$old_pane")" ]; then
    prompt="herdr-single: the $provider 5h window has reset. Continue the run at $run as its lead (skill directory: $skill_dir): run status.sh --run $run, read progress.json and handoff.md, collect any dispatched helpers with dispatch.sh --collect, and carry on with the next unfinished step through validation and authorized delivery. Inherit the original task and recorded authorization; do not ask whether to continue."
    printf '%s\n' "$prompt" > "$run/lead-resume.md"
    lead_update '
lead.update(status="awaiting_delivery", pending_prompt=args[0], in_place=True)
lead.setdefault("resumes", []).append({"at": now, "reason": args[1]})
for k in ("parked_reason", "parked_until"):
    lead.pop(k, None)
' "$prompt" "window reset"
    rm -f "$run/lead.warning"
    echo "RESUME: $old_name continues in pane $old_pane after the $provider window reset"
    "$here/handoff.sh" --run "$run" --deliver
    exit 0
  fi
  reason="the $provider 5h window reset; the previous lead's pane is gone"
  [ "$HERDR_SINGLE_LEAD_RESUME" != fresh ] || reason="the $provider 5h window reset (HERDR_SINGLE_LEAD_RESUME=fresh)"
fi

# A fresh lead of the same provider, at the recorded successor model and effort.
gen=$(json_get "$lj" generation); gen=$((${gen:-1} + 1))
name="lead$gen"
repo=$(json_get "$run/state.json" repo)
selection=$(lead_models select --lead-file "$lj" --provider "$provider")
mapfile -t destination <<<"$selection"
target_model=${destination[0]}; target_effort=${destination[1]:-}

# Read only the old lead's session. No input is sent to that pane, even when quota is
# exhausted or a command is still running there.
python3 "$here/goal-handoff.py" capture --run "$run" --pane "$old_pane" >/dev/null

if [ "$provider" = codex ]; then
  args=(-m "$target_model" -c "model_reasoning_effort=${target_effort:-$HERDR_SINGLE_CODEX_LEAD_EFFORT}")
  grep -q -- '--no-daemon' <<<"$(codex --help 2>&1 || true)" && args+=(--no-daemon)
  # The successor runs unattended, so it cannot stop at approval prompts.
  if [ "$HERDR_SINGLE_CODEX_ACCESS" = full ]; then args+=(-s danger-full-access -a never); else args+=(-s workspace-write -a on-request); fi
else
  args=(--model "$target_model" --add-dir "$HERDR_SINGLE_STATE_ROOT" --add-dir "$skill_dir" --permission-mode "$HERDR_SINGLE_CLAUDE_MODE")
  [ -z "$target_effort" ] || args+=(--effort "$target_effort")
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
herdr agent start "$name" --kind "$provider" --pane "$pane" --timeout 90000 -- "${args[@]}" >/dev/null 2>&1 || true

prompt="Use the herdr-single skill to resume the run at $run as its new lead (skill directory: $skill_dir). The previous lead $old_name stopped: $reason. Start with the section 'Resume a run' in SKILL.md and execute it now. Inherit the original task and recorded user authorization; do not ask whether to continue. Read goal-native.json, goal-transfer.json if present, state.json, progress.json and goal.json. Respect paused, blocked, completed or budget-exhausted goal state; never reactivate it automatically. If goal-transfer.json says needs_budget_tool, use your native goal tool to restore the objective with only the known remaining token budget before starting work; never create an unlimited replacement. For an unavailable native reader/command, recover the portable goal as the skill permits and report the limitation without blocking authorized work. Inspect and collect every already-running helper/process without duplicating it, then continue all unfinished steps through validation and authorized delivery/cleanup. Do not stop after a status update or dispatch. Only a genuinely unresolved required user decision or actual approval dialog blocks dependent work; keep making independent progress."
printf '%s\n' "$prompt" > "$run/lead-resume.md"
lead_update '
old = {k: lead.get(k) for k in ("name", "pane", "model")}
lead.setdefault("history", []).append(old | {"ended_at": now, "reason": args[4]})
lead.update(name=args[0], pane=args[1], generation=int(args[2]), status="awaiting_approval",
            pending_prompt=args[3], model=args[5])
for k in ("parked_reason", "parked_until", "in_place"):
    lead.pop(k, None)
' "$name" "$pane" "$gen" "$prompt" "$reason" "$target_model"
rm -f "$run/lead.warning"

echo "HANDOFF: $old_name ($old_pane) -> $name ($provider, $target_model, pane $pane): $reason"
echo "The previous lead's pane stays open. If you are the previous lead: stop now and do nothing more in this run."
dialog=$(pane_dialog "$pane")
if [ -n "$dialog" ]; then
  echo "successor shows a startup dialog: \"$dialog\". The user answers it in pane $pane; the panel then delivers the resume prompt."
  exit 0
fi
"$here/handoff.sh" --run "$run" --deliver
