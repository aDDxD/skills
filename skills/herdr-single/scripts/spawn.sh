#!/usr/bin/env bash
# Spawn one herdr-single session in a single call: worktree (implementers), pane placed in
# the run's balanced layout, agent start with the standard access profile, and a
# state.json record.
# Re-running for a name whose baseline already exists in this run reuses its worktree
# (useful to restart a crashed agent).
#
# Usage: spawn.sh --run DIR --name NAME [--provider codex|claude] [--role implementer|reviewer]
#                 [--model MODEL] [--effort LEVEL]
#                 [--base-from NAME] [--review-of AUTHOR] [--continue-from NAME]
#                 [--split-from PANE_ID] [--direction right|down]
#                 [baseline options: --from-head | --patch F, --copy P...; --deps D..., --deps-auto]
#                 [--dry-run] | --recheck
#   Provider: the run's subscription (state.json). --provider may only repeat it; a session
#             on the other subscription is refused, because the run must work with that
#             subscription inactive.
#   Model:    the provider's helper model for implementers and its reviewer model for
#             reviewers (config.env), unless --model names another model of that provider.
#   Effort:   HERDR_SINGLE_HELPER_EFFORT (default xhigh); --effort overrides it.
#   --base-from NAME the worktree starts from NAME's worktree instead of the user's checkout.
#   --review-of lead a read-only reviewer of the lead's own changes ($RUN/lead.patch), in the
#                    user's checkout; any other AUTHOR is reviewed in that author's worktree.
# Without --split-from the pane is placed by place.py: it splits the largest pane the
# run owns along its longer side (never the lead's pane), trying the caller's tab
# first, and opens a new tab when no pane has room.
# Implementers start from the source's current checkout (--from-checkout) by default, so
# they see uncommitted work and integration does not conflict on stale files.
# Access profiles (override in ~/.config/herdr-single/config.env):
#   codex implementer : danger-full-access, never ask   (HERDR_SINGLE_CODEX_ACCESS=full)
#   claude implementer: --permission-mode auto           (HERDR_SINGLE_CLAUDE_MODE=auto)
#   codex reviewer    : read-only sandbox, never ask
#   claude reviewer   : dontAsk, edit tools disallowed
set -euo pipefail
here=$(dirname "$(realpath "$0")")
. "$here/common.sh"

run=""; name=""; provider=""; role=implementer; review_of=""; split_from=""; direction=right; dry=no; recheck=no
model=""; effort=""; continue_from=""; base_from=""
base_args=(); source_mode=checkout
while [ $# -gt 0 ]; do
  case "$1" in
    --run) run=$2; shift 2 ;;
    --name) name=$2; shift 2 ;;
    --provider) provider=$2; shift 2 ;;
    --role) role=$2; shift 2 ;;
    --review-of) review_of=$2; shift 2 ;;
    --level) die "herdr-single has no sibling lead and no levels: every session is a helper or reviewer of the run's lead" ;;
    --model) model=$2; shift 2 ;;
    --effort) effort=$2; shift 2 ;;
    --tier) die "--tier is not supported: use --model to choose any model of the run's provider" ;;
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
[ "$name" != lead ] || die "'lead' is reserved for the run's lead"

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
run_kind=$(run_provider "$run")
case "$run_kind" in codex|claude) ;; *) die "state.json records no provider; start the run with run-init.sh" ;; esac
[ -n "$provider" ] || provider=$run_kind
case "$provider" in codex|claude) ;; *) die "--provider must be codex or claude" ;; esac
[ "$provider" = "$run_kind" ] \
  || die "this run uses only $run_kind; herdr-single never starts a $provider session (use herdr-duo to combine subscriptions)"
case "$role" in implementer|reviewer) ;; *) die "--role must be implementer or reviewer" ;; esac
case "$direction" in right|down) ;; *) die "--direction must be right or down" ;; esac
[ "$role" = implementer ] || [ -n "$review_of" ] || die "a reviewer needs --review-of AUTHOR"
[ -z "$continue_from" ] || [ "$role" = implementer ] || die "--continue-from is for implementers"
[ -z "$base_from" ] || { [ "$role" = implementer ] && [ -z "$continue_from" ]; } || die "--base-from is for new implementers"

owner=lead
level=helper
[ -z "$base_from" ] || require_owner "$run" "$base_from"
[ -z "$continue_from" ] || require_owner "$run" "$continue_from"

# Model: the provider's helper model for implementers, its reviewer model for reviewers.
if [ -z "$model" ]; then
  if [ "$role" = reviewer ]; then model=$(model_for "$provider" reviewer); else model=$(model_for "$provider" helper); fi
fi
case "$provider:$model" in
  claude:claude*|codex:*) ;;
  *) die "model '$model' is not a $provider model" ;;
esac
[ "$provider" != codex ] || [[ "$model" != claude* ]] || die "model '$model' is not a codex model"
[ -n "$effort" ] || effort=$HERDR_SINGLE_HELPER_EFFORT
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
elif [ "$review_of" = lead ]; then
  # The lead's own changes: a read-only session in the user's checkout reads $RUN/lead.patch.
  wt=$repo
  baseline_note="reviews the lead's changes (read-only, in the user's checkout)"
  read_dirs=("$sdir" "$run")
else
  author_dir="$run/$review_of"
  [ -f "$author_dir/baseline.json" ] || die "no baseline for author '$review_of' in this run"
  wt=$(json_get "$author_dir/baseline.json" worktree)
  baseline_note="reviews $review_of in its worktree"
  read_dirs=("$sdir" "$author_dir")
fi

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
  elif [ "$HERDR_SINGLE_CODEX_ACCESS" = full ]; then
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
    args+=(--permission-mode "$HERDR_SINGLE_CLAUDE_MODE")
  fi
fi

# Herdr types the agent command into the pane's shell, so arguments must be shell-safe words.
for a in "${args[@]}"; do
  [[ "$a" =~ ^[A-Za-z0-9_./,=:@+-]+$ ]] || die "argument not shell-safe for herdr agent start: '$a' (avoid spaces/quotes in HERDR_SINGLE_* paths and values)"
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
