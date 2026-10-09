#!/usr/bin/env bash
# Create an isolated, detached worker worktree and record its baseline tree.
# Changes no branch, index, or commit in the repository. If any step fails,
# the worktree it just created is removed so the same path can be retried.
#
# Usage: baseline.sh --repo DIR --worktree DIR --state DIR
#                    [--from-checkout] [--patch FILE] [--copy RELPATH]...
#                    [--deps RELDIR]... [--deps-auto]
#   --from-checkout  reproduce the lead's uncommitted state: tracked changes plus
#                    untracked, non-ignored files (secret-looking names skipped)
#   --patch / --copy selective alternative: a reviewed patch and chosen untracked files
#   --deps / --deps-auto  give the worktree ignored dependency dirs (node_modules,
#                    .venv, ...): reflink copy when the filesystem supports it,
#                    otherwise a symlink. Both are excluded from baseline and delta.
set -euo pipefail
. "$(dirname "$(realpath "$0")")/common.sh"

repo=""; wt=""; state=""; patch=""; from_checkout=no; deps_auto=no; copies=(); deps=()
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo=$2; shift 2 ;;
    --worktree) wt=$2; shift 2 ;;
    --state) state=$2; shift 2 ;;
    --patch) patch=$2; shift 2 ;;
    --copy) copies+=("$2"); shift 2 ;;
    --from-checkout) from_checkout=yes; shift ;;
    --deps) deps+=("${2%/}"); shift 2 ;;
    --deps-auto) deps_auto=yes; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -n "$repo" ] && [ -n "$wt" ] && [ -n "$state" ] || die "--repo, --worktree and --state are required"
[ "$from_checkout" = no ] || [ -z "$patch" ] || die "use either --from-checkout or --patch, not both"

repo=$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null) || die "not a git repository: $repo"
wt=$(realpath -m "$wt")
state=$(realpath -m "$state")
[ ! -e "$wt" ] || die "worktree path already exists: $wt (integrate or remove it, or use another name)"
[ ! -e "$state/baseline.json" ] || die "baseline already recorded in $state"

if [ "$deps_auto" = yes ]; then
  while IFS= read -r d; do
    d=${d%/}
    for name in $HERDR_DUO_DEPS_NAMES; do
      [ "$(basename "$d")" = "$name" ] && deps+=("$d")
    done
  done < <(git -C "$repo" ls-files --others --ignored --exclude-standard --directory)
fi

for rel in "${copies[@]+"${copies[@]}"}" "${deps[@]+"${deps[@]}"}"; do
  case "$rel" in /*|*..*) die "path must be relative and inside the repo: $rel" ;; esac
done
for rel in "${copies[@]+"${copies[@]}"}"; do
  is_secret_path "$rel" && die "refusing to copy a secret-looking file: $rel"
  [ -f "$repo/$rel" ] || die "copy source is not a file: $rel"
done
for d in "${deps[@]+"${deps[@]}"}"; do
  [ -d "$repo/$d" ] || die "deps source is not a directory: $d"
  [ -z "$(git -C "$repo" ls-files -- "$d" | head -n 1)" ] || die "deps dir has tracked files, refusing: $d"
done

mkdir -p "$state"
head=$(git -C "$repo" rev-parse HEAD)

created=no
cleanup() {
  if [ "$created" = yes ] && [ ! -f "$state/baseline.json" ]; then
    git -C "$repo" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"
    git -C "$repo" worktree prune >/dev/null 2>&1 || true
    echo "baseline failed: removed the partial worktree $wt" >&2
  fi
}
trap cleanup EXIT

# Forget registrations of worktrees whose directories are gone (e.g. a deleted state
# dir); otherwise git refuses to reuse the stable path. Existing worktrees are untouched.
git -C "$repo" worktree prune >/dev/null 2>&1 || true
# Detached worktree: no branch is created and the repository HEAD is untouched.
if ! git -C "$repo" worktree add --detach "$wt" "$head" >/dev/null 2>"$state/worktree-add.log"; then
  cat "$state/worktree-add.log" >&2
  die "git worktree add failed for $wt"
fi
created=yes

skipped=()
if [ "$from_checkout" = yes ]; then
  patch="$state/from-checkout.patch"
  git -C "$repo" diff --binary HEAD > "$patch"
  [ -s "$patch" ] || patch=""
  while IFS= read -r -d '' rel; do
    if is_secret_path "$rel"; then skipped+=("$rel"); else copies+=("$rel"); fi
  done < <(git -C "$repo" ls-files --others --exclude-standard -z)
fi

patch_sha=""
if [ -n "$patch" ]; then
  patch=$(realpath "$patch")
  git -C "$wt" apply --check --binary "$patch"
  git -C "$wt" apply --binary "$patch"
  patch_sha=$(sha256sum "$patch" | cut -d' ' -f1)
fi

for rel in "${copies[@]+"${copies[@]}"}"; do
  mkdir -p "$wt/$(dirname "$rel")"
  cp -p "$repo/$rel" "$wt/$rel"
done

deps_json="[]"
excludes=()
for d in "${deps[@]+"${deps[@]}"}"; do
  mkdir -p "$wt/$(dirname "$d")"
  if cp -a --reflink=always "$repo/$d" "$wt/$d" 2>/dev/null; then
    method=reflink
  else
    rm -rf "${wt:?}/$d"
    ln -s "$repo/$d" "$wt/$d"
    method=symlink
  fi
  # Exclude explicitly only what git does not already ignore (a symlink does not match
  # a "dir/" pattern); naming an ignored path in a pathspec makes git add fail.
  if git -C "$wt" check-ignore -q -- "$d"; then exclude=false; else exclude=true; excludes+=(":(exclude)$d"); fi
  deps_json=$(python3 -c 'import json,sys; l=json.loads(sys.argv[1]); l.append({"path": sys.argv[2], "method": sys.argv[3], "exclude": sys.argv[4] == "true"}); print(json.dumps(l))' "$deps_json" "$d" "$method" "$exclude")
done

# Baseline tree from a private index, so the worktree's own index stays untouched.
tree=$(GIT_INDEX_FILE="$state/baseline.index" git -C "$wt" add -A -- . "${excludes[@]+"${excludes[@]}"}" \
  && GIT_INDEX_FILE="$state/baseline.index" git -C "$wt" write-tree)

list_json() { python3 -c 'import json,sys; print(json.dumps([a for a in sys.argv[1:] if a]))' "$@"; }
python3 - "$state/baseline.json" "$repo" "$head" "$wt" "$tree" "$patch_sha" \
  "$(list_json "${copies[@]+"${copies[@]}"}")" "$(list_json "${skipped[@]+"${skipped[@]}"}")" "$deps_json" <<'PY'
import json, sys, datetime
path, repo, head, wt, tree, patch_sha, copies, skipped, deps = sys.argv[1:]
data = {
    "repo": repo, "head": head, "worktree": wt, "baseline_tree": tree,
    "patch_sha256": patch_sha or None, "copies": json.loads(copies),
    "skipped_secrets": json.loads(skipped), "deps": json.loads(deps),
    "created_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
}
with open(path, "w") as f:
    json.dump(data, f, indent=2)
summary = dict(data, copies=len(data["copies"]))
print(json.dumps(summary, indent=2))
PY
