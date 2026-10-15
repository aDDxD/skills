#!/usr/bin/env bash
# Pass the principal lead role of a run to the other subscription, for example when the
# principal's 5h window runs out. The panel calls it automatically; the principal may
# call it itself at a safe point when it was warned that its quota is low.
#   - A live sibling lead of the other provider is promoted: it already knows the task,
#     so no new session starts and no context has to be rebuilt.
#   - Otherwise a fresh lead of the pair model (Opus or Sol) starts below the old pane.
# The successor's 5h quota is checked first. A provider that ran out is not tried again
# until its window resets (the real reset time when known, else 5 hours).
# The previous lead's pane is left open and never typed into; the lead fence in
# common.sh stops it from acting on the run if it wakes up again.
#
# Usage: handoff.sh --run DIR --reason TEXT [--to codex|claude] [--lead-model MODEL]
#        handoff.sh --run DIR --deliver     send the resume prompt once the successor is ready
#        handoff.sh --run DIR --adopt       make the calling pane the principal (manual takeover)
# Exit: 0 done or waiting for the successor, 3 handoff disabled, 4 no provider with quota left.
set -euo pipefail
here=$(dirname "$(realpath "$0")")
. "$here/common.sh"
skill_dir=$(dirname "$here")

run=""; reason=""; to=""; mode=handoff; lead_model=""
while [ $# -gt 0 ]; do
  case "$1" in
    --run) run=$2; shift 2 ;;
    --reason) reason=$2; shift 2 ;;
    --to) to=$2; shift 2 ;;
    --lead-model) lead_model=$2; shift 2 ;;
    --deliver) mode=deliver; shift ;;
    --adopt) mode=adopt; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -f "$run/state.json" ] || die "no state.json in '$run'"
run=$(realpath "$run")
lj="$run/lead.json"
[ -f "$lj" ] || die "no lead.json in $run (run-init records the lead when it starts inside a Herdr pane)"

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
  [ -z "$(pane_dialog "$pane")" ] || { echo "successor $name still shows a dialog in pane $pane"; exit 0; }
  st=$(agent_status "$pane")
  [ "$st" = idle ] || [ "$st" = "done" ] || { echo "successor $name is $st; waiting"; exit 0; }
  if [ -n "$(json_get "$lj" promoted)" ]; then
    # A promoted sibling keeps its own session and goal; it only needs the new role.
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
  adopted_model=$(lead_models detect --pane "$me")
  lead_update '
lead.setdefault("history", []).append({k: lead.get(k) for k in ("name", "pane", "kind", "model")} | {"ended_at": now, "reason": "adopted by another pane"})
lead.update(pane=args[0], kind=args[1] or None, name="lead" + str(lead.get("generation", 1) + 1),
            generation=lead.get("generation", 1) + 1, status="active", model=args[2] or None)
lead.pop("promoted", None)
' "$me" "$kind" "$adopted_model"
  rm -f "$run/lead.warning"
  echo "this pane ($me) is now the lead of $run"
  exit 0
fi

[ -n "$reason" ] || die "--reason is required"
require_lead "$run"
mkdir "$run/handoff.lock" 2>/dev/null || die "a handoff is already in progress ($run/handoff.lock)"
trap 'rmdir "$run/handoff.lock" 2>/dev/null || true' EXIT

if [ -n "$lead_model" ]; then
  [ -z "$(json_get "$lj" initial_model)" ] || die "the initial lead model is already recorded; --lead-model only fills a missing one"
  profile=$(lead_models init --pane "$(json_get "$lj" pane)" --model "$lead_model")
  lead_update 'lead.update(__import__("json").loads(args[0]))' "$profile"
fi

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

# Quota of both pools now; unknown quota never blocks a handoff.
qjson=$(quota json 2>/dev/null || echo '{}')

# A provider whose window ran out in this run waits for its reset; so does a successor
# whose window is already (nearly) empty. Returns the time to wait for, or nothing.
blocked=$(python3 - "$lj" "$target" "$qjson" "$HERDR_DUO_LEAD_HANDOFF_PCT" <<'PY'
import datetime, json, sys, time
lead, target, q, pct = json.load(open(sys.argv[1])), sys.argv[2], json.loads(sys.argv[3] or "{}"), float(sys.argv[4])
until = lead.get("exhausted_until", {}).get(target)
legacy = lead.get("exhausted", {}).get(target)
if legacy:
    until = max(until or 0, datetime.datetime.fromisoformat(legacy).timestamp() + 5 * 3600)
x = q.get(target, {})
if x.get("known") and x["left"] <= pct:
    until = max(until or 0, x.get("resets_at") or time.time() + 5 * 3600)
if until and until > time.time():
    print(time.strftime("%H:%M", time.localtime(until)))
PY
)
if [ -n "$blocked" ]; then
  lead_update 'lead["status"] = "stranded"; lead["stranded_reason"] = args[0]' "$reason; $target has no 5h quota until $blocked"
  echo "NO SUCCESSOR: $target has no 5h quota until $blocked. The run waits; the panel resumes it when a window resets (SKILL.md, Resume a run)."
  exit 4
fi

old_pane=$(json_get "$lj" pane); old_name=$(json_get "$lj" name)
gen=$(json_get "$lj" generation); gen=$((${gen:-1} + 1))
name="lead$gen"
repo=$(json_get "$run/state.json" repo)
# When the old provider's window resets it may lead again.
old_until=$(python3 -c 'import json,sys,time; x=json.loads(sys.argv[1] or "{}").get(sys.argv[2],{}); print(int(x.get("resets_at") or time.time()+5*3600))' "$qjson" "${cur_kind:-none}" 2>/dev/null || echo 0)

# Promotion: the live sibling of the target provider becomes the principal.
sib=$(python3 - "$run/state.json" "$target" <<'PY'
import json, sys
s, target = json.load(open(sys.argv[1])), sys.argv[2]
r = next((r for r in s.get("workers", []) if r.get("level") == "sibling"
          and r.get("status") not in ("cleaned", "promoted", "escalated") and r.get("provider") == target), None)
if r and r.get("pane"):
    print(r["name"], r["pane"], r.get("model") or "")
PY
)
if [ -n "$sib" ]; then
  read -r sib_name sib_pane sib_model <<<"$sib"
  if [ -n "$(agent_status "$sib_pane")" ]; then
    prompt="herdr-duo: you are now the PRINCIPAL lead of the run at $run (skill directory: $skill_dir). The previous principal $old_name stopped: $reason. Bring your current slice to a safe point, then follow 'Resume a run' in SKILL.md as the principal: integrate your own slice (your former record is '$sib_name'), collect every helper of the run, and continue the remaining plan through validation and authorized delivery. Inherit the original task and recorded authorization; do not ask whether to continue."
    printf '%s\n' "$prompt" > "$run/lead-resume.md"
    state_edit "$run" '
sib = args[0]
for r in state.get("workers", []) + state.get("reviewers", []):
    if r.get("name") == sib: r["status"] = "promoted"
    elif r.get("owner") == sib: r["owner"] = "lead"
' "$sib_name"
    lead_update '
old = {k: lead.get(k) for k in ("name", "pane", "kind", "model")}
lead.setdefault("history", []).append(old | {"ended_at": now, "reason": args[4]})
if old["kind"]:
    lead.setdefault("exhausted_until", {})[old["kind"]] = int(args[7])
lead.update(name=args[0], pane=args[1], kind=args[2], generation=int(args[3]),
            status="awaiting_delivery", pending_prompt=args[5], model=args[6] or None, promoted=args[8])
lead.pop("stranded_reason", None)
' "$name" "$sib_pane" "$target" "$gen" "$reason" "$prompt" "$sib_model" "$old_until" "$sib_name"
    rm -f "$run/lead.warning" "$run/$sib_name.warning"
    echo "HANDOFF: $old_name ($old_pane) -> sibling $sib_name promoted to principal $name ($target, pane $sib_pane): $reason"
    echo "The previous lead's pane stays open. If you are the previous lead: stop now and do nothing more in this run."
    "$here/handoff.sh" --run "$run" --deliver
    exit 0
  fi
fi

# No live sibling: start a fresh lead of the pair model.
selection=$(lead_models select --lead-file "$lj" --provider "$target")
mapfile -t destination <<<"$selection"
target_model=${destination[0]}; target_effort=${destination[1]:-}

# Read only the old leader's session. No input is sent to that pane, even when
# quota is exhausted or a command is still running there.
python3 "$here/goal-handoff.py" capture --run "$run" --pane "$old_pane" >/dev/null

if [ "$target" = codex ]; then
  args=(-m "$target_model" -c "model_reasoning_effort=${target_effort:-$HERDR_DUO_SOL_EFFORT}")
  grep -q -- '--no-daemon' <<<"$(codex --help 2>&1 || true)" && args+=(--no-daemon)
  # The successor runs unattended, so it cannot stop at approval prompts.
  if [ "$HERDR_DUO_CODEX_ACCESS" = full ]; then args+=(-s danger-full-access -a never); else args+=(-s workspace-write -a on-request); fi
else
  args=(--model "$target_model" --add-dir "$HERDR_DUO_STATE_ROOT" --add-dir "$skill_dir" --permission-mode "$HERDR_DUO_CLAUDE_MODE")
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
herdr agent start "$name" --kind "$target" --pane "$pane" --timeout 90000 -- "${args[@]}" >/dev/null 2>&1 || true

prompt="Use the herdr-duo skill to resume the run at $run as its new principal lead (skill directory: $skill_dir). The previous lead $old_name stopped: $reason. Start with the section 'Resume a run' in SKILL.md and execute it now. Inherit the original task and recorded user authorization; do not ask whether to continue. Read goal-native.json, goal-transfer.json if present, state.json, progress.json and goal.json. Respect paused, blocked, completed or budget-exhausted goal state; never reactivate it automatically. A native usage_limited goal may continue on the other provider as the skill describes. If goal-transfer.json says needs_budget_tool, use your native goal tool to restore the objective with only the known remaining token budget before starting work; never create an unlimited replacement. For an unavailable native reader/command, recover the portable goal as the skill permits and report the limitation without blocking authorized work. Inspect and collect every already-running worker/process without duplicating it, then continue all unfinished steps through validation and authorized delivery/cleanup. Do not stop after a status update or dispatch. Only a genuinely unresolved required user decision or actual approval dialog blocks dependent work; keep making independent progress."
printf '%s\n' "$prompt" > "$run/lead-resume.md"
lead_update '
old = {k: lead.get(k) for k in ("name", "pane", "kind", "model")}
lead.setdefault("history", []).append(old | {"ended_at": now, "reason": args[4]})
if old["kind"]:
    lead.setdefault("exhausted_until", {})[old["kind"]] = int(args[7])
lead.update(name=args[0], pane=args[1], kind=args[2], generation=int(args[3]),
            status="awaiting_approval", pending_prompt=args[5], model=args[6])
lead.pop("stranded_reason", None)
lead.pop("promoted", None)
' "$name" "$pane" "$target" "$gen" "$reason" "$prompt" "$target_model" "$old_until"
rm -f "$run/lead.warning"

echo "HANDOFF: $old_name ($old_pane) -> $name ($target, $target_model, pane $pane): $reason"
echo "The previous lead's pane stays open. If you are the previous lead: stop now and do nothing more in this run."
dialog=$(pane_dialog "$pane")
if [ -n "$dialog" ]; then
  echo "successor shows a startup dialog: \"$dialog\". The user answers it in pane $pane; the panel then delivers the resume prompt."
  exit 0
fi
"$here/handoff.sh" --run "$run" --deliver
