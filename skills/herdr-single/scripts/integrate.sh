#!/usr/bin/env bash
# Verify and optionally apply a worker delta to its source: the user's checkout (principal
# only), or a sibling lead's worktree for that sibling's helpers (--base-from).
# Refuses when any touched path no longer matches the baseline tree, so
# intervening user edits are never overwritten. Stages and commits nothing.
#
# Usage: integrate.sh --state DIR --patch FILE [--apply]
#   without --apply: check only (exit 0 = would apply cleanly)
#   exit 3: conflict with baseline or patch does not apply
set -euo pipefail
. "$(dirname "$(realpath "$0")")/common.sh"

state=""; patch=""; apply=no
while [ $# -gt 0 ]; do
  case "$1" in
    --state) state=$2; shift 2 ;;
    --patch) patch=$2; shift 2 ;;
    --apply) apply=yes; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -n "$state" ] && [ -n "$patch" ] || die "--state and --patch are required"

state=$(realpath -m "$state")
patch=$(realpath "$patch")
bj="$state/baseline.json"
[ -f "$bj" ] || die "no baseline.json in $state"
run_dir=$(dirname "$state")
[ -s "$patch" ] || { echo "patch is empty: nothing to integrate"; exit 0; }

repo=$(json_get "$bj" repo)
base=$(json_get "$bj" baseline_tree)
git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || die "target is not a git repository: $repo"
if [ -f "$run_dir/state.json" ]; then
  require_member "$run_dir"
  who=$(member "$run_dir")
  if [ "$who" != lead ] && [ "$who" != panel ]; then
    [ "$(realpath -m "$repo")" = "$(realpath -m "$(record_get "$run_dir" "$who" worktree)")" ] \
      || die "a sibling integrates only into its own worktree; the principal integrates into the user's checkout"
  fi
fi

# Blob id of what is on disk now, matching how git stores it (symlinks by target).
disk_blob() {
  local f="$repo/$1"
  if [ -L "$f" ]; then
    readlink -n -- "$f" | git -C "$repo" hash-object --stdin
  elif [ -f "$f" ]; then
    git -C "$repo" hash-object -- "$f"
  elif [ -e "$f" ]; then
    echo non-file
  else
    echo none
  fi
}

# Every path the patch touches: NUL-separated numstat, which lists both sides of renames.
stats=$(mktemp)
trap 'rm -f "$stats"' EXIT
if ! git apply --numstat -z "$patch" > "$stats"; then
  echo "cannot inspect patch: $patch" >&2
  exit 3
fi
mapfile -d '' -t fields < "$stats"
paths=()
i=0
while [ $i -lt ${#fields[@]} ]; do
  f=${fields[$i]}
  if [[ "$f" == *$'\t'*$'\t' ]]; then
    # rename/copy record: "add\tdel\t" followed by old and new paths
    paths+=("${fields[$((i + 1))]}" "${fields[$((i + 2))]}"); i=$((i + 3))
  else
    paths+=("${f#*$'\t'*$'\t'}"); i=$((i + 1))
  fi
done

conflicts=0
for p in "${paths[@]}"; do
  [ -n "$p" ] || continue
  # <tree>:<path> resolves literally (no globbing), including symlink blobs.
  expected=$(git -C "$repo" rev-parse -q --verify "$base:$p" 2>/dev/null || echo none)
  actual=$(disk_blob "$p")
  expected_mode=$(git -C "$repo" ls-tree --format='%(objectmode)' "$base" -- ":(literal)$p")
  actual_mode=none
  if [ -L "$repo/$p" ]; then actual_mode=120000
  elif [ -f "$repo/$p" ]; then
    if [ -x "$repo/$p" ]; then actual_mode=100755; else actual_mode=100644; fi
  fi
  if [ "$expected" != "$actual" ] || { [ -n "$expected_mode" ] && [ "$expected_mode" != "$actual_mode" ]; }; then
    echo "CONFLICT: $p differs from baseline (expected $expected ${expected_mode:-none}, found $actual $actual_mode)" >&2
    conflicts=$((conflicts + 1))
  fi
done

if [ "$conflicts" -gt 0 ]; then
  echo "refusing to integrate: $conflicts path(s) changed since the baseline. Resolve deliberately." >&2
  exit 3
fi

if ! git -C "$repo" apply --check --binary "$patch"; then
  echo "patch does not apply cleanly to $repo" >&2
  exit 3
fi

if [ "$apply" = yes ]; then
  git -C "$repo" apply --binary "$patch"
  # Record what was integrated, so cleanup.sh can prove the worktree holds nothing newer.
  sha256sum "$patch" | cut -d' ' -f1 > "$state/integrated.sha"
  # Advance the baseline to the tree this patch produced, so a later fix round's delta
  # contains only the new work and integrates cleanly on top of this one.
  if [ -f "$patch.meta" ] && read -r from to < "$patch.meta" && [ "$from" = "$base" ]; then
    python3 - "$bj" "$to" <<'PY'
import json, sys, datetime
path, to = sys.argv[1:]
d = json.load(open(path))
d.setdefault("integrated_trees", []).append({"from": d["baseline_tree"], "to": to,
    "at": datetime.datetime.now(datetime.timezone.utc).isoformat()})
d["baseline_tree"] = to
json.dump(d, open(path, "w"), indent=2)
PY
    echo "baseline advanced to the integrated tree ${to:0:12}"
  else
    echo "WARN: baseline not advanced (no matching $patch.meta); a later delta from this worker will include this patch again" >&2
  fi
  echo "applied (no index change, no commit): ${#paths[@]} path(s)"
  printf '  %s\n' "${paths[@]}"
else
  echo "check ok: ${#paths[@]} path(s) apply cleanly; re-run with --apply to write files"
fi
