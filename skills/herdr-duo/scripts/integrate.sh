#!/usr/bin/env bash
# Verify and optionally apply a worker delta to the lead's checkout.
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
require_lead "$(dirname "$state")"
[ -s "$patch" ] || { echo "patch is empty: nothing to integrate"; exit 0; }

repo=$(json_get "$bj" repo)
base=$(json_get "$bj" baseline_tree)
git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || die "target is not a git repository: $repo"

# Blob id of what is on disk now, matching how git stores it (symlinks by target).
disk_blob() {
  local f="$repo/$1"
  if [ -L "$f" ]; then
    printf %s "$(readlink "$f")" | git -C "$repo" hash-object --stdin
  elif [ -f "$f" ]; then
    git -C "$repo" hash-object -- "$f"
  else
    echo none
  fi
}

# Every path the patch touches: NUL-separated numstat, which lists both sides of renames.
mapfile -d '' -t fields < <(git apply --numstat -z "$patch")
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
  if [ "$expected" != "$actual" ]; then
    echo "CONFLICT: $p differs from baseline (expected $expected, found $actual)" >&2
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
