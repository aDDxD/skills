#!/usr/bin/env bash
# Compute a worker's delta against its recorded baseline tree.
# Captures additions, modifications, deletions, renames, binary files and modes;
# dependency dirs recorded by baseline.sh are excluded.
# Creates git objects only; no commit, branch or worktree-index change.
#
# Usage: delta.sh --state DIR --out FILE [--worktree DIR]
#   --worktree defaults to the one recorded in baseline.json
set -euo pipefail
. "$(dirname "$(realpath "$0")")/common.sh"

state=""; wt=""; out=""
while [ $# -gt 0 ]; do
  case "$1" in
    --state) state=$2; shift 2 ;;
    --worktree) wt=$2; shift 2 ;;
    --out) out=$2; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -n "$state" ] && [ -n "$out" ] || die "--state and --out are required"

state=$(realpath -m "$state")
out=$(realpath -m "$out")
bj="$state/baseline.json"
[ -f "$bj" ] || die "no baseline.json in $state; run baseline.sh first"

base=$(json_get "$bj" baseline_tree)
recorded_wt=$(json_get "$bj" worktree)
wt=${wt:-$recorded_wt}
wt=$(cd "$wt" && pwd -P)
[ "$wt" = "$(realpath -m "$recorded_wt")" ] || die "worktree $wt does not match the baseline worktree $recorded_wt"

mapfile -t excludes < <(deps_excludes "$bj")
rm -f "$state/current.index"
cur=$(GIT_INDEX_FILE="$state/current.index" git -C "$wt" add -A -- . "${excludes[@]+"${excludes[@]}"}" \
  && GIT_INDEX_FILE="$state/current.index" git -C "$wt" write-tree)

# Sidecar for integrate.sh: which trees this patch goes from and to.
printf '%s %s\n' "$base" "$cur" > "$out.meta"

if [ "$cur" = "$base" ]; then
  : > "$out"
  python3 -c 'import json,sys; print(json.dumps({"changed": 0, "files": [], "patch": sys.argv[1], "note": "no delta against baseline"}))' "$out"
  exit 0
fi

git -C "$wt" diff --binary --no-color "$base" "$cur" > "$out"
names=$(git -C "$wt" diff --name-status --no-color "$base" "$cur")
stat=$(git -C "$wt" diff --shortstat "$base" "$cur")

python3 - "$out" "$names" "$stat" <<'PY'
import json, sys
patch, names, stat = sys.argv[1], sys.argv[2], sys.argv[3]
files = [line.split("\t") for line in names.splitlines() if line.strip()]
text = open(patch, errors="replace").read()
print(json.dumps({
    "changed": len(files),
    "shortstat": stat.strip(),
    "files": [{"status": f[0], "paths": f[1:]} for f in files],
    "patch": patch,
    "binary_present": "GIT binary patch" in text,
    "mode_changes": sum(1 for l in text.splitlines() if l.startswith("old mode ")),
}, indent=2))
PY
