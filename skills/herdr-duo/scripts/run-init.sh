#!/usr/bin/env bash
# Start a herdr-duo run for any git repository. Creates the run directory and
# state.json outside the repository, then prints the facts the lead needs as
# literal absolute paths (shell variables do not survive between tool calls).
#
# Usage: run-init.sh --repo DIR [--goal TEXT] [--commit] [--push]
#   --commit / --push only when the user's initial request explicitly asked for them.
set -euo pipefail
. "$(dirname "$(realpath "$0")")/common.sh"

repo=""; goal=""; commit=false; push=false
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo=$2; shift 2 ;;
    --goal) goal=$2; shift 2 ;;
    --commit) commit=true; shift ;;
    --push) push=true; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -n "$repo" ] || die "--repo is required"
repo=$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository: $repo"

slug="$(basename "$repo")-$(printf %s "$repo" | sha256sum | cut -c1-8)"
run="$HERDR_DUO_STATE_ROOT/runs/$slug/$(date -u +%Y%m%dT%H%M%SZ)"
[ ! -e "$run" ] || run="$run-$$"
# Stable worktree root per repository, so agent trust prompts are answered once per worker name.
wt_root="$HERDR_DUO_STATE_ROOT/wt/$slug"
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
  for name in $HERDR_DUO_DEPS_NAMES; do
    [ "$(basename "$d")" = "$name" ] && deps="$deps $d"
  done
done < <(git -C "$repo" ls-files --others --ignored --exclude-standard --directory 2>/dev/null)

stale=""
for d in "$wt_root"/*/; do
  [ -d "$d" ] && stale="$stale $(basename "$d")"
done

python3 - "$run/state.json" "$repo" "$branch" "$head" "$default_branch" "$commit" "$push" "$goal" "$wt_root" <<'PY'
import json, sys, datetime
path, repo, branch, head, default_branch, commit, push, goal, wt_root = sys.argv[1:]
json.dump({
    "goal": goal, "repo": repo, "branch": branch, "head": head,
    "default_branch": default_branch or None,
    "commit_authorized": commit == "true", "push_authorized": push == "true",
    "wt_root": wt_root, "workers": [], "reviewers": [], "status": "planning",
    "created_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
}, open(path, "w"), indent=2)
PY

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
access: luna=$HERDR_DUO_LUNA_ACCESS ($HERDR_DUO_LUNA_MODEL, effort $HERDR_DUO_LUNA_EFFORT)  haiku=$HERDR_DUO_HAIKU_MODE ($HERDR_DUO_HAIKU_MODEL)
EOF
