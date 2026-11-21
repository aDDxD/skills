#!/usr/bin/env bash
# Start a herdr-single run for any git repository. Creates the run directory and
# state.json outside the repository, then prints the facts the lead needs as
# literal absolute paths (shell variables do not survive between tool calls).
#
# Usage: run-init.sh --repo DIR [--goal TEXT] [--provider codex|claude] [--lead-model MODEL]
#                    [--lead-effort LEVEL] [--commit] [--push] [--no-panel]
#   --provider fixes the run's subscription; by default it is HERDR_SINGLE_PROVIDER, else
#   the agent of the calling pane. Every helper, reviewer and successor lead uses it.
#   --lead-model / --lead-effort supply the lead's actual model and effort when the exact
#   session cannot be read; a successor lead inherits that effort.
#   --commit / --push only when the user's initial request explicitly asked for them.
# Inside Herdr it also records the calling pane as the run's lead (lead.json) and opens
# the status panel with the lead watchdog to the right of it.
set -euo pipefail
. "$(dirname "$(realpath "$0")")/common.sh"

repo=""; goal=""; commit=false; push=false; panel=yes; lead_model=""; lead_effort=""; provider=$HERDR_SINGLE_PROVIDER
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo=$2; shift 2 ;;
    --goal) goal=$2; shift 2 ;;
    --provider) provider=$2; shift 2 ;;
    --lead-model) lead_model=$2; shift 2 ;;
    --lead-effort) lead_effort=$2; shift 2 ;;
    --commit) commit=true; shift ;;
    --push) push=true; shift ;;
    --no-panel) panel=no; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -n "$repo" ] || die "--repo is required"
lead_kind=""
if [ -n "${HERDR_PANE_ID:-}" ]; then
  lead_kind=$(herdr agent get "$HERDR_PANE_ID" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["agent"].get("agent") or "")' 2>/dev/null || true)
fi
[ -n "$provider" ] || provider=$lead_kind
case "$provider" in
  codex|claude) ;;
  "") die "cannot tell which subscription this run uses (this pane's agent is unknown); pass --provider codex|claude" ;;
  *) die "--provider must be codex or claude" ;;
esac
if [ -n "$lead_effort" ] && [ -z "$(lead_models effort --provider codex --value "$lead_effort")" ]; then
  die "--lead-effort must be one of: low medium high xhigh max ultra"
fi
top=$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null) \
  || die "not a git repository: $repo. Run 'git init' and make an initial commit (workers start from HEAD)"
repo=$top
git -C "$repo" rev-parse --verify -q HEAD >/dev/null \
  || die "no commits in $repo yet. Make an initial commit (workers start from HEAD)"

slug="$(basename "$repo")-$(printf %s "$repo" | sha256sum | cut -c1-8)"
run="$HERDR_SINGLE_STATE_ROOT/runs/$slug/$(date -u +%Y%m%dT%H%M%SZ)"
[ ! -e "$run" ] || run="$run-$$"
# Stable worktree root per repository, so agent trust prompts are answered once per worker name.
wt_root="$HERDR_SINGLE_STATE_ROOT/wt/$slug"
mkdir -p "$run" "$wt_root"

branch=$(git -C "$repo" symbolic-ref -q --short HEAD || echo "(detached)")
head=$(git -C "$repo" rev-parse HEAD)
default_branch=$(git -C "$repo" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)
if [ -z "$default_branch" ]; then
  for b in main master trunk; do
    git -C "$repo" show-ref -q --verify "refs/heads/$b" && { default_branch=$b; break; }
  done
fi
modified=$(git -C "$repo" status --porcelain --untracked-files=no | wc -l)
untracked=$(git -C "$repo" ls-files --others --exclude-standard | wc -l)

instructions=""
for f in AGENTS.md CLAUDE.md CONTRIBUTING.md README.md package.json Makefile justfile pyproject.toml Cargo.toml go.mod; do
  [ -e "$repo/$f" ] && instructions="$instructions $f"
done

deps=""
while IFS= read -r d; do
  d=${d%/}
  for name in $HERDR_SINGLE_DEPS_NAMES; do
    [ "$(basename "$d")" = "$name" ] && deps="$deps $d"
  done
done < <(git -C "$repo" ls-files --others --ignored --exclude-standard --directory 2>/dev/null)

stale=""
for d in "$wt_root"/*/; do
  [ -d "$d" ] && stale="$stale $(basename "$d")"
done

python3 - "$run/state.json" "$repo" "$branch" "$head" "$default_branch" "$commit" "$push" "$goal" "$wt_root" "$provider" <<'PY'
import json, sys, datetime
path, repo, branch, head, default_branch, commit, push, goal, wt_root, provider = sys.argv[1:]
json.dump({
    "goal": goal, "provider": provider, "repo": repo, "branch": branch, "head": head,
    "default_branch": default_branch or None,
    "commit_authorized": commit == "true", "push_authorized": push == "true",
    "wt_root": wt_root, "workers": [], "reviewers": [], "status": "planning",
    "created_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
}, open(path, "w"), indent=2)
PY

if [ "$provider" = codex ]; then access="codex=$HERDR_SINGLE_CODEX_ACCESS"; else access="claude=$HERDR_SINGLE_CLAUDE_MODE"; fi
cat <<EOF
SKILL_DIR=$(dirname "$(dirname "$(realpath "$0")")")
RUN=$run
WT_ROOT=$wt_root
REPO=$repo
branch: $branch  head: ${head:0:12}  default_branch: ${default_branch:-unknown}
commit_authorized: $commit  push_authorized: $push
uncommitted: $modified modified tracked, $untracked untracked (use --from-checkout if workers need them)
instruction_files:${instructions:- none}
deps_candidates:${deps:- none}  (pass --deps-auto to copy them)
stale_worktrees_in_WT_ROOT:${stale:- none}  (integrate or remove before reusing a name)
provider: $provider (fixed for this run; nothing starts on the other subscription)
models: lead=$(model_for "$provider" lead)  helper=$(model_for "$provider" helper)  reviewer=$(model_for "$provider" reviewer); helpers and reviewers at effort $HERDR_SINGLE_HELPER_EFFORT; any $provider model via spawn.sh --model
access: $access
EOF
quota line --provider "$provider" || true

# The lead is the pane that started the run; the panel and handoff build on this record.
if [ -n "${HERDR_PANE_ID:-}" ]; then
  [ -z "$lead_kind" ] || [ "$lead_kind" = "$provider" ] \
    || echo "WARN: this pane runs $lead_kind but the run uses $provider; helpers and successors start on $provider" >&2
  profile_args=(init --pane "$HERDR_PANE_ID" --provider "$provider")
  [ -z "$lead_model" ] || profile_args+=(--model "$lead_model")
  [ -z "$lead_effort" ] || profile_args+=(--effort "$lead_effort")
  lead_profile=$(lead_models "${profile_args[@]}")
  panel_pane=""
  if [ "$panel" = yes ]; then
    script_dir=$(dirname "$(realpath "$0")")
    if [[ "$script_dir$run" =~ ^[A-Za-z0-9_./,=:@+-]+$ ]] \
      && split_out=$(herdr pane split "$HERDR_PANE_ID" --direction right --cwd "$repo" --no-focus 2>/dev/null); then
      panel_pane=$(printf %s "$split_out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["pane"]["pane_id"])' 2>/dev/null || true)
      [ -z "$panel_pane" ] || {
        herdr pane rename "$panel_pane" "herdr-single panel" >/dev/null 2>&1 || true
        herdr pane run "$panel_pane" "$script_dir/panel.sh --run $run" >/dev/null 2>&1 || true
      }
    fi
  fi
  python3 - "$run/lead.json" "$HERDR_PANE_ID" "$provider" "$panel_pane" "$lead_profile" <<'PY'
import json, sys
path, pane, kind, panel, profile = sys.argv[1:]
json.dump({"name": "lead1", "pane": pane, "kind": kind, "generation": 1, "status": "active",
           "panel_pane": panel or None, **json.loads(profile)}, open(path, "w"), indent=2)
PY
  echo "lead: pane $HERDR_PANE_ID ($provider)  panel: ${panel_pane:-not started}  lead resume: $HERDR_SINGLE_LEAD_RESUME"
  echo "lead model: $(json_get "$run/lead.json" model)  effort: $(json_get "$run/lead.json" effort || true)  successor: $(json_get "$run/lead.json" successor)"
fi

# Hint for a failed origin check. Never prints the URL itself, so no credentials leak.
push_hint() {
  case "$1" in
    https://*)
      if compgen -G "$HOME/.ssh/id_*.pub" >/dev/null; then
        echo "credentials are not available to git for https; an SSH key exists, so run 'git remote set-url origin git@github.com:OWNER/REPO.git' (ask the user first)"
      else
        echo "credentials are not available to git for https; run 'gh auth setup-git' (ask the user first)"
      fi ;;
    *) echo "check the remote URL and access: git ls-remote origin" ;;
  esac
}

origin_url=$(git -C "$repo" remote get-url origin 2>/dev/null || true)
# Mask user:password@ in the printed URL.
origin_shown=$(printf '%s' "$origin_url" | sed -E 's#^([a-zA-Z+.-]+://)[^/@]*@#\1***@#')
echo "remote: ${origin_shown:-none}"
if [ "$push" = true ]; then
  if [ -z "$origin_url" ]; then
    echo "push_check: skipped (no origin remote)"
  elif GIT_TERMINAL_PROMPT=0 timeout 15 git -C "$repo" ls-remote --exit-code origin HEAD >/dev/null 2>&1; then
    echo "push_check: ok"
  else
    echo "push_check: FAILED ($(push_hint "$origin_url"))"
  fi
fi
