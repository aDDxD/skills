#!/usr/bin/env bash
# Spawn one herdr-duo session in a single call: worktree (implementers), sibling pane,
# agent start with the standard access profile, and a state.json record.
# Re-running for a name whose baseline already exists in this run reuses its worktree
# (useful to restart a crashed agent).
#
# Usage: spawn.sh --run DIR --name NAME --provider codex|claude --role implementer|reviewer
#                 [--tier base|strong] [--continue-from NAME]
#                 [--review-of AUTHOR] [--split-from PANE_ID] [--direction right|down]
#                 [baseline options: --from-head | --patch F, --copy P...; --deps D..., --deps-auto]
#                 [--dry-run]
# Implementers start from the lead's current checkout (--from-checkout) by default, so
# they see uncommitted work and integration does not conflict on stale files.
# --from-head starts from HEAD only; --patch/--copy select exactly what to carry over.
# Access profiles (override in ~/.config/herdr-duo/config.env):
#   codex implementer : danger-full-access, never ask   (HERDR_DUO_LUNA_ACCESS=full)
#   claude implementer: --permission-mode auto           (HERDR_DUO_HAIKU_MODE=auto)
#   codex reviewer    : read-only sandbox, never ask
#   claude reviewer   : dontAsk, edit tools disallowed
# Tiers: base = Luna / Haiku (scale horizontally as the plan allows);
#        strong = Sol / Sonnet (one live strong session per run, never more).
# --continue-from NAME: an implementer that takes over NAME's worktree and state dir
#   (used by escalate.sh); NAME's baseline, delta and integration history carry over.
set -euo pipefail
here=$(dirname "$(realpath "$0")")
. "$here/common.sh"

run=""; name=""; provider=""; role=""; review_of=""; split_from=""; direction=right; dry=no; recheck=no
tier=base; continue_from=""
base_args=(); source_mode=checkout
while [ $# -gt 0 ]; do
  case "$1" in
    --run) run=$2; shift 2 ;;
    --name) name=$2; shift 2 ;;
    --provider) provider=$2; shift 2 ;;
    --role) role=$2; shift 2 ;;
    --review-of) review_of=$2; shift 2 ;;
    --tier) tier=$2; shift 2 ;;
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
[[ "$name" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || die "invalid agent name '$name' (must match [a-z][a-z0-9_-]{0,31})"

set_record_status() { set_field "$run" "$name" status "$1"; }

# --recheck: after the user answered a startup dialog, confirm the session is usable.
if [ "${recheck:-no}" = yes ]; then
  pane=$(python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); print(next((r["pane"] for k in ("workers","reviewers") for r in s.get(k,[]) if r["name"]==sys.argv[2]), ""))' "$run/state.json" "$name")
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
case "$direction" in right|down) ;; *) die "--direction must be right or down" ;; esac
case "$tier" in base|strong) ;; *) die "--tier must be base or strong" ;; esac
[ "$role" = implementer ] || [ -n "$review_of" ] || die "a reviewer needs --review-of AUTHOR"
[ -z "$continue_from" ] || [ "$role" = implementer ] || die "--continue-from is for implementers"
if [ "$tier" = strong ]; then
  busy=$(live_strong "$run")
  [ -z "$busy" ] || [ "$busy" = "$name" ] \
    || die "strong session '$busy' is still live; strong sessions never run in parallel. Finish and clean it up first"
fi

[ "$source_mode" = checkout ] && base_args+=(--from-checkout)

repo=$(json_get "$run/state.json" repo)
wt_root=$(json_get "$run/state.json" wt_root)
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
  wt="$wt_root/$name"
  if [ -f "$sdir/baseline.json" ]; then
    wt=$(json_get "$sdir/baseline.json" worktree)
    [ -d "$wt" ] || die "baseline exists but its worktree is gone: $wt"
    baseline_note="reused existing worktree"
  else
    need_baseline=yes
    baseline_note="(dry-run) would create"
  fi
  read_dirs=("$sdir")
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
  if [ "$tier" = strong ]; then
    args=(-m "$HERDR_DUO_SOL_MODEL" -c "model_reasoning_effort=$HERDR_DUO_SOL_EFFORT")
  else
    args=(-m "$HERDR_DUO_LUNA_MODEL" -c "model_reasoning_effort=$HERDR_DUO_LUNA_EFFORT")
  fi
  # A shared daemon started outside Herdr can lose this pane's environment.
  # Older Codex releases have no daemon flag and already execute locally.
  codex_help=$(codex --help 2>&1) || codex_help=""
  if grep -q -- '--no-daemon' <<<"$codex_help"; then
    args+=(--no-daemon)
  fi
  if [ "$role" = reviewer ]; then
    args+=(-s read-only -a never)
  elif [ "$HERDR_DUO_LUNA_ACCESS" = full ]; then
    args+=(-s danger-full-access -a never)
  else
    args+=(-s workspace-write -a on-request)
  fi
else
  if [ "$tier" = strong ]; then args=(--model "$HERDR_DUO_SONNET_MODEL"); else args=(--model "$HERDR_DUO_HAIKU_MODEL"); fi
  for d in "${read_dirs[@]}"; do args+=(--add-dir "$d"); done
  if [ "$role" = reviewer ]; then
    args+=(--permission-mode dontAsk --disallowedTools "Edit,Write,NotebookEdit")
  else
    args+=(--permission-mode "$HERDR_DUO_HAIKU_MODE")
  fi
fi

# Herdr types the agent command into the pane's shell, so arguments must be shell-safe words.
for a in "${args[@]}"; do
  [[ "$a" =~ ^[A-Za-z0-9_./,=:@+-]+$ ]] || die "argument not shell-safe for herdr agent start: '$a' (avoid spaces/quotes in HERDR_DUO_* paths and values)"
done

# Create the worktree only after every argument is validated, so a refusal leaves nothing behind.
if [ "$need_baseline" = yes ] && [ "$dry" = no ]; then
  "$here/baseline.sh" --repo "$repo" --worktree "$wt" --state "$sdir" "${base_args[@]+"${base_args[@]}"}" > "$sdir/baseline.out"
  baseline_note="created: $(json_get "$sdir/baseline.json" baseline_tree | cut -c1-12)"
fi

if [ -n "$split_from" ]; then
  split_cmd=(herdr pane split "$split_from" --direction "$direction" --cwd "$wt" --no-focus)
else
  split_cmd=(herdr pane split --current --direction "$direction" --cwd "$wt" --no-focus)
fi

if [ "$dry" = yes ]; then
  printf 'DRY RUN %s (%s, %s, tier '"$tier"')\n  worktree: %s [%s; source=%s]\n  split: %s\n  start: herdr agent start %s --kind %s --pane <new> --timeout 90000 -- %s\n' \
    "$name" "$provider" "$role" "$wt" "$baseline_note" "$source_mode" "${split_cmd[*]}" "$name" "$provider" "${args[*]}"
  exit 0
fi

split_out=$("${split_cmd[@]}" 2>&1) || { echo "$split_out" >&2; die "pane split failed"; }
pane=$(printf %s "$split_out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["pane"]["pane_id"])') \
  || die "could not read pane id from: $split_out"

status=ready
start_out=$(herdr agent start "$name" --kind "$provider" --pane "$pane" --timeout 90000 -- "${args[@]}" 2>&1) || status=not_ready
# Herdr may call a pane ready while a trust dialog is on screen; check the screen itself.
dialog=$(pane_dialog "$pane")
[ -z "$dialog" ] || status=needs_approval

state_edit "$run" '
name, provider, role, pane, wt, sdir, status, review_of, agent_args, tier, continue_from = args
key = "workers" if role == "implementer" else "reviewers"
rec = {"name": name, "provider": provider, "role": role, "tier": tier, "pane": pane, "worktree": wt,
       "state_dir": sdir, "status": status, "args": agent_args, "fix_rounds": 0}
if review_of:
    rec["review_of"] = review_of
if continue_from:
    rec["continues"] = continue_from
state[key] = [r for r in state.get(key, []) if r.get("name") != name] + [rec]
' "$name" "$provider" "$role" "$pane" "$wt" "$sdir" "$status" "$review_of" "${args[*]}" "$tier" "$continue_from"

echo "name=$name provider=$provider role=$role tier=$tier status=$status pane=$pane"
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
