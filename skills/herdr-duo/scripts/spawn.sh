#!/usr/bin/env bash
# Spawn one herdr-duo session in a single call: worktree (implementers), pane placed in
# the run's balanced layout, agent start with the standard access profile, and a
# state.json record with its owner.
# Re-running for a name whose baseline already exists in this run reuses its worktree
# (useful to restart a crashed agent).
#
# Usage: spawn.sh --run DIR --name NAME --provider codex|claude [--role implementer|reviewer]
#                 [--level helper|sibling] [--model MODEL] [--effort LEVEL]
#                 [--base-from NAME] [--review-of AUTHOR] [--continue-from NAME]
#                 [--split-from PANE_ID] [--direction right|down]
#                 [baseline options: --from-head | --patch F, --copy P...; --deps D..., --deps-auto]
#                 [--dry-run] | --recheck
#   --level sibling  the other subscription's lead (Opus or Sol, the fixed pair). Only the
#                    principal opens it; one live sibling per run, never of the principal's
#                    own provider. It owns a slice and opens its own helpers.
#   --level helper   (default) Luna or Haiku unless --model names another model. Any lead
#                    opens as many as the task needs, from either subscription.
#   Effort: a sibling inherits the principal's recorded effort; helpers run at
#   HERDR_DUO_HELPER_EFFORT (default xhigh). --effort overrides either, on both CLIs.
#   --base-from NAME the worktree starts from NAME's worktree instead of the user's checkout,
#                    so a sibling's helpers build on the sibling's slice and integrate into it.
#   Owner: the calling lead ("lead" for the principal, or the sibling's name). A sibling
#   dispatches and cleans up only the sessions it owns.
# Without --split-from the pane is placed by place.py: it splits the largest pane the
# run owns along its longer side (never the principal's pane), trying the caller's tab
# first, and opens a new tab when no pane has room.
# Implementers start from the source's current checkout (--from-checkout) by default, so
# they see uncommitted work and integration does not conflict on stale files.
# Access profiles (override in ~/.config/herdr-duo/config.env):
#   codex implementer : danger-full-access, never ask   (HERDR_DUO_CODEX_ACCESS=full)
#   claude implementer: --permission-mode auto           (HERDR_DUO_CLAUDE_MODE=auto)
#   codex reviewer    : read-only sandbox, never ask
#   claude reviewer   : dontAsk, edit tools disallowed
set -euo pipefail
here=$(dirname "$(realpath "$0")")
. "$here/common.sh"
skill_dir=$(dirname "$here")

run=""; name=""; provider=""; role=implementer; review_of=""; split_from=""; direction=right; dry=no; recheck=no
level=helper; model=""; effort=""; continue_from=""; base_from=""
base_args=(); source_mode=checkout
while [ $# -gt 0 ]; do
  case "$1" in
    --run) run=$2; shift 2 ;;
    --name) name=$2; shift 2 ;;
    --provider) provider=$2; shift 2 ;;
    --role) role=$2; shift 2 ;;
    --review-of) review_of=$2; shift 2 ;;
    --level) level=$2; shift 2 ;;
    --model) model=$2; shift 2 ;;
    --effort) effort=$2; shift 2 ;;
    --tier) die "--tier was removed: use --level helper|sibling, and --model to choose any model" ;;
    --base-from) base_from=$2; shift 2 ;;
    --continue-from) continue_from=$2; shift 2 ;;
    --split-from) split_from=$2; shift 2 ;;
    --direction) direction=$2; shift 2 ;;
    --from-checkout) source_mode="checkout"; shift ;;
    --from-head) source_mode="head"; shift ;;
    --patch|--copy) source_mode="selective"; base_args+=("$1" "$2"); shift 2 ;;
    --deps) base_args+=("$1" "$2"); shift 2 ;;
    --deps-auto) base_args+=("$1"); shift ;;
    --dry-run) dry=yes; shift ;;
    --recheck) recheck=yes; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -f "$run/state.json" ] || die "no state.json in '$run'; run run-init.sh first"
run=$(realpath "$run")
require_member "$run"
[[ "$name" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || die "invalid agent name '$name' (must match [a-z][a-z0-9_-]{0,31})"
[ "$name" != lead ] || die "'lead' is reserved for the principal"

set_record_status() { set_field "$run" "$name" status "$1"; }

# --recheck: after the user answered a startup dialog, confirm the session is usable.
if [ "${recheck:-no}" = yes ]; then
  require_owner "$run" "$name"
  pane=$(record_get "$run" "$name" pane)
  [ -n "$pane" ] || die "no recorded session named $name in this run"
  dialog=$(pane_dialog "$pane")
  st=$(agent_status "$name")
  if [ -z "$dialog" ] && { [ "$st" = idle ] || [ "$st" = "done" ]; }; then
    set_record_status ready; echo "name=$name status=ready pane=$pane"; exit 0
  fi
  echo "name=$name status=${st:-unknown} pane=$pane dialog=${dialog:-none}" >&2
  exit 1
fi
case "$provider" in codex|claude) ;; *) die "--provider must be codex or claude" ;; esac
case "$role" in implementer|reviewer) ;; *) die "--role must be implementer or reviewer" ;; esac
case "$level" in helper|sibling) ;; *) die "--level must be helper or sibling" ;; esac
case "$direction" in right|down) ;; *) die "--direction must be right or down" ;; esac
[ "$role" = implementer ] || [ -n "$review_of" ] || die "a reviewer needs --review-of AUTHOR"
[ -z "$continue_from" ] || [ "$role" = implementer ] || die "--continue-from is for implementers"
[ -z "$base_from" ] || { [ "$role" = implementer ] && [ -z "$continue_from" ]; } || die "--base-from is for new implementers"

owner=$(member "$run")
[ "$owner" != panel ] || owner=lead
# Reusing a name reuses its worktree and replaces its record: only its owner may do that.
[ -z "$(record_get "$run" "$name" name)" ] || require_owner "$run" "$name"
if [ "$level" = sibling ]; then
  [ "$owner" = lead ] || die "only the principal opens the sibling lead"
  [ "$role" = implementer ] || die "the sibling lead is an implementer"
  lead_kind=$( [ -f "$run/lead.json" ] && json_get "$run/lead.json" kind || true)
  [ -z "$lead_kind" ] || [ "$lead_kind" != "$provider" ] \
    || die "the sibling must come from the other subscription than the principal ($lead_kind)"
  # Check and reserve in one locked state edit, so two launches cannot both pass.
  [ "$dry" = yes ] && reserve=no || reserve=yes
  busy=$(state_edit "$run" '
name, provider, reserve = args
workers = state.setdefault("workers", [])
# Busy: another live sibling, or any launch of this name still starting. Restarting the
# live session of the same name (a crashed agent) is allowed.
live = next((r for r in workers if r.get("level") == "sibling" and (
    (r["name"] != name and r.get("status") not in ("cleaned", "promoted", "escalated"))
    or (r["name"] == name and r.get("status") == "starting"))), None)
mine = next((r for r in workers if r.get("name") == name), None)
if mine is not None and mine.get("level", "helper") != "sibling":
    print("!level")  # a name keeps its level: a former helper name cannot become the sibling
elif live:
    print(live["name"])
elif reserve == "yes":
    mine = next((r for r in workers if r.get("name") == name), None)
    if mine is None:
        workers.append({"name": name, "provider": provider, "role": "implementer",
                        "level": "sibling", "owner": "lead", "status": "starting", "reserved_from": None})
    else:
        mine["reserved_from"] = mine.get("status")
        mine["status"] = "starting"
' "$name" "$provider" "$reserve")
  [ "$busy" != "!level" ] || die "'$name' was a helper in this run; choose another name for the sibling"
  [ -z "$busy" ] || die "sibling '$busy' is still live; a run has one sibling lead"
  # Release the reservation if this launch fails before the session is registered.
  release_reservation() {
    state_edit "$run" '
for r in list(state.get("workers", [])):
    if r.get("name") == args[0] and r.get("status") == "starting":
        if r.get("reserved_from") is None:
            state["workers"].remove(r)
        else:
            r["status"] = r.pop("reserved_from")' "$name"
  }
  [ "$reserve" = no ] || trap release_reservation EXIT
fi
[ -z "$base_from" ] || require_owner "$run" "$base_from"
[ -z "$continue_from" ] || require_owner "$run" "$continue_from"

# Model: the pair for a sibling, Luna/Haiku for a helper, unless --model overrides it.
if [ -z "$model" ]; then
  if [ "$level" = sibling ]; then
    if [ "$provider" = codex ]; then model=$HERDR_DUO_SOL_MODEL; else model=$HERDR_DUO_OPUS_MODEL; fi
  else
    if [ "$provider" = codex ]; then model=$HERDR_DUO_LUNA_MODEL; else model=$HERDR_DUO_HAIKU_MODEL; fi
  fi
fi
if [ -z "$effort" ]; then
  if [ "$level" = sibling ]; then
    effort=$(lead_models effort --provider "$provider" --lead-file "$run/lead.json")
    [ -n "$effort" ] || [ "$provider" != codex ] || effort=$HERDR_DUO_LEAD_CODEX_EFFORT
  else
    effort=$HERDR_DUO_HELPER_EFFORT
  fi
fi
if [ -n "$effort" ]; then
  checked=$(lead_models effort --provider "$provider" --value "$effort")
  [ -n "$checked" ] || die "effort '$effort' is not valid for $provider"
  effort=$checked
fi

[ "$source_mode" = checkout ] && base_args+=(--from-checkout)

repo=$(json_get "$run/state.json" repo)
wt_root=$(json_get "$run/state.json" wt_root)
source_repo=$repo
sdir="$run/$name"
mkdir -p "$sdir"
own_dir=$sdir

need_baseline=no
if [ -n "$continue_from" ]; then
  sdir=$(record_get "$run" "$continue_from" state_dir)
  [ -f "$sdir/baseline.json" ] || die "no baseline for '$continue_from' in this run"
  wt=$(json_get "$sdir/baseline.json" worktree)
  [ -d "$wt" ] || die "worktree of '$continue_from' is gone: $wt"
  baseline_note="continues $continue_from in its worktree"
  read_dirs=("$own_dir" "$sdir")
elif [ "$role" = implementer ]; then
  if [ -n "$base_from" ]; then
    source_repo=$(record_get "$run" "$base_from" worktree)
    [ -d "$source_repo" ] || die "worktree of '$base_from' is gone: $source_repo"
  fi
  wt="$wt_root/$name"
  if [ -f "$sdir/baseline.json" ]; then
    wt=$(json_get "$sdir/baseline.json" worktree)
    [ -d "$wt" ] || die "baseline exists but its worktree is gone: $wt"
    baseline_note="reused existing worktree"
  else
    need_baseline=yes
    baseline_note="(dry-run) would create from ${base_from:-the user checkout}"
  fi
  read_dirs=("$sdir")
else
  author_dir="$run/$review_of"
  [ -f "$author_dir/baseline.json" ] || die "no baseline for author '$review_of' in this run"
  wt=$(json_get "$author_dir/baseline.json" worktree)
  baseline_note="reviews $review_of in its worktree"
  read_dirs=("$sdir" "$author_dir")
fi
# A sibling runs the skill's scripts and writes its helpers' assignments under the run.
[ "$level" != sibling ] || read_dirs=("$HERDR_DUO_STATE_ROOT" "$skill_dir")

# Standard access profiles.
args=()
if [ "$provider" = codex ]; then
  args=(-m "$model" -c "model_reasoning_effort=$effort")
  # A shared daemon started outside Herdr can lose this pane's environment.
  # Older Codex releases have no daemon flag and already execute locally.
  codex_help=$(codex --help 2>&1) || codex_help=""
  if grep -q -- '--no-daemon' <<<"$codex_help"; then
    args+=(--no-daemon)
  fi
  if [ "$role" = reviewer ]; then
    args+=(-s read-only -a never)
  elif [ "$HERDR_DUO_CODEX_ACCESS" = full ]; then
    args+=(-s danger-full-access -a never)
  else
    args+=(-s workspace-write -a on-request)
  fi
else
  args=(--model "$model")
  [ -z "$effort" ] || args+=(--effort "$effort")
  for d in "${read_dirs[@]}"; do args+=(--add-dir "$d"); done
  if [ "$role" = reviewer ]; then
    args+=(--permission-mode dontAsk --disallowedTools "Edit,Write,NotebookEdit")
  else
    args+=(--permission-mode "$HERDR_DUO_CLAUDE_MODE")
  fi
fi

# Herdr types the agent command into the pane's shell, so arguments must be shell-safe words.
for a in "${args[@]}"; do
  [[ "$a" =~ ^[A-Za-z0-9_./,=:@+-]+$ ]] || die "argument not shell-safe for herdr agent start: '$a' (avoid spaces/quotes in HERDR_DUO_* paths and values)"
done

# Create the worktree only after every argument is validated, so a refusal leaves nothing behind.
if [ "$need_baseline" = yes ] && [ "$dry" = no ]; then
  "$here/baseline.sh" --repo "$source_repo" --worktree "$wt" --state "$sdir" "${base_args[@]+"${base_args[@]}"}" > "$sdir/baseline.out"
  origin=${base_from:-the user checkout}
  [ "$source_mode" != head ] || origin="HEAD of ${base_from:-the user checkout}"
  baseline_note="created from $origin: $(json_get "$sdir/baseline.json" baseline_tree | cut -c1-12)"
fi

if [ -n "$split_from" ]; then
  split_cmd=(herdr pane split "$split_from" --direction "$direction" --cwd "$wt" --no-focus)
else
  split_cmd=(python3 "$here/place.py" "$run" "$wt")
fi

if [ "$dry" = yes ]; then
  printf 'DRY RUN %s (%s, %s, level %s, owner %s)\n  worktree: %s [%s; source=%s]\n  split: %s\n  start: herdr agent start %s --kind %s --pane <new> --timeout 90000 -- %s\n' \
    "$name" "$provider" "$role" "$level" "$owner" "$wt" "$baseline_note" "$source_mode" "${split_cmd[*]}" "$name" "$provider" "${args[*]}"
  exit 0
fi

tab=""
if [ -z "$split_from" ] && placed=$("${split_cmd[@]}" 2>/dev/null) && [ -n "$placed" ]; then
  read -r pane tab <<<"$placed"
else
  # Explicit placement, or place.py could not read the layout: split next to the caller.
  [ -n "$split_from" ] || split_cmd=(herdr pane split --current --direction "$direction" --cwd "$wt" --no-focus)
  split_out=$("${split_cmd[@]}" 2>&1) || { echo "$split_out" >&2; die "pane split failed"; }
  pane=$(printf %s "$split_out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["pane"]["pane_id"])') \
    || die "could not read pane id from: $split_out"
fi

status=ready
start_out=$(herdr agent start "$name" --kind "$provider" --pane "$pane" --timeout 90000 -- "${args[@]}" 2>&1) || status=not_ready
# Herdr may call a pane ready while a trust dialog is on screen; check the screen itself.
dialog=$(pane_dialog "$pane")
[ -z "$dialog" ] || status=needs_approval

state_edit "$run" '
name, provider, role, pane, wt, sdir, status, review_of, agent_args, level, continue_from, tab, owner, model, base_from = args
key = "workers" if role == "implementer" else "reviewers"
rec = {"name": name, "provider": provider, "role": role, "level": level, "model": model, "owner": owner,
       "pane": pane, "worktree": wt, "state_dir": sdir, "status": status, "args": agent_args, "fix_rounds": 0}
for k, v in (("review_of", review_of), ("continues", continue_from), ("tab", tab), ("base_from", base_from)):
    if v:
        rec[k] = v
state[key] = [r for r in state.get(key, []) if r.get("name") != name] + [rec]
' "$name" "$provider" "$role" "$pane" "$wt" "$sdir" "$status" "$review_of" "${args[*]}" "$level" "$continue_from" "$tab" "$owner" "$model" "$base_from"

trap - EXIT
echo "name=$name provider=$provider model=$model effort=${effort:-default} role=$role level=$level owner=$owner status=$status pane=$pane"
echo "worktree=$wt [$baseline_note]"
echo "state_dir=$sdir"
if [ "$status" = needs_approval ]; then
  echo "STARTUP DIALOG in pane $pane: \"$dialog\"" >&2
  echo "Do not answer it yourself. Ask the user to answer it in that pane (folder trust is a one-time decision per path)," >&2
  echo "then run: $here/spawn.sh --run $run --name $name --recheck" >&2
  exit 1
elif [ "$status" != ready ]; then
  echo "agent start did not reach ready: $(printf %s "$start_out" | tr '\n' ' ' | cut -c1-400)" >&2
  echo "inspect: herdr pane read $pane --source recent-unwrapped --lines 40   (pane kept for inspection; close it with herdr pane close $pane)" >&2
  exit 1
fi
