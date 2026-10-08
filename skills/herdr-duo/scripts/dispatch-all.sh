#!/usr/bin/env bash
# Dispatch workers in parallel, then print their results in the requested order.
# Usage: dispatch-all.sh --run DIR [--timeout-min N] [name...]
# With no names, all workers recorded in DIR/state.json are dispatched.
set -euo pipefail
script_dir=$(dirname "$(realpath "$0")")
run=""; timeout_min=30; names=()
while [ $# -gt 0 ]; do
  case "$1" in
    --run) [ $# -ge 2 ] || { echo "missing value for --run" >&2; exit 2; }; run=$2; shift 2 ;;
    --timeout-min) [ $# -ge 2 ] || { echo "missing value for --timeout-min" >&2; exit 2; }; timeout_min=$2; shift 2 ;;
    --*) echo "unknown option: $1" >&2; exit 2 ;;
    *) names+=("$1"); shift ;;
  esac
done
[ -n "$run" ] || { echo "usage: dispatch-all.sh --run DIR [--timeout-min N] [name...]" >&2; exit 2; }
[ -f "$run/state.json" ] || { echo "no state.json in '$run'" >&2; exit 2; }
run=$(realpath "$run")
if [ ${#names[@]} -eq 0 ]; then
  mapfile -t names < <(python3 - "$run/state.json" <<'PY'
import json, sys
state = json.load(open(sys.argv[1]))
for worker in state.get("workers", []):
    print(worker["name"])
PY
)
fi
[ ${#names[@]} -gt 0 ] || { echo "no workers to dispatch" >&2; exit 2; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
pids=()
for i in "${!names[@]}"; do
  bash "$script_dir/dispatch.sh" --run "$run" --name "${names[$i]}" --timeout-min "$timeout_min" >"$tmp/$i.out" 2>&1 &
  pids[$i]=$!
done
max_rc=0
for i in "${!names[@]}"; do
  rc=0
  wait "${pids[$i]}" || rc=$?
  [ "$rc" -le "$max_rc" ] || max_rc=$rc
done
for i in "${!names[@]}"; do
  cat "$tmp/$i.out"
done
exit "$max_rc"
