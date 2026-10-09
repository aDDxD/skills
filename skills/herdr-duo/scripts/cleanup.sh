#!/usr/bin/env bash
# Close a session's pane and remove its worktree, but only when nothing would be lost:
# the worktree's current delta must be exactly what integrate.sh applied (or empty).
# --discard removes it anyway; use it only when the user agreed to drop that work.
#
# Usage: cleanup.sh --run DIR --name NAME [--discard] [--keep-pane]
# Exit: 0 cleaned, 8 refused because the worktree holds unintegrated work.
set -euo pipefail
here=$(dirname "$(realpath "$0")")
. "$here/common.sh"

run=""; name=""; discard=no; keep_pane=no
while [ $# -gt 0 ]; do
  case "$1" in
    --run) run=$2; shift 2 ;;
    --name) name=$2; shift 2 ;;
    --discard) discard=yes; shift ;;
    --keep-pane) keep_pane=yes; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -f "$run/state.json" ] || die "no state.json in '$run'"
run=$(realpath "$run")

read -r role pane wt sdir sharers < <(python3 -c '
import json, sys
s = json.load(open(sys.argv[1]))
recs = [r for k in ("workers", "reviewers") for r in s.get(k, [])]
r = next((r for r in recs if r["name"] == sys.argv[2]), None)
if not r:
    print("- - - - -"); sys.exit()
# Other live implementers in the same worktree (an escalation continues in place).
others = [o["name"] for o in recs if o["name"] != r["name"] and o.get("role") == "implementer"
          and o.get("worktree") == r.get("worktree") and o.get("status") not in ("cleaned", "escalated")]
print(r["role"], r.get("pane") or "-", r.get("worktree") or "-", r.get("state_dir") or "-", ",".join(others) or "-")
' "$run/state.json" "$name")
[ "$role" != "-" ] || die "no recorded session named $name in this run"

if [ "$keep_pane" = no ] && [ "$pane" != "-" ]; then
  herdr pane close "$pane" >/dev/null 2>&1 && echo "closed pane $pane" || echo "pane $pane already gone"
fi

# Reviewers work inside the author's worktree; only implementers own one.
if [ "$role" = implementer ] && [ "$sharers" != "-" ]; then
  echo "worktree $wt kept: still used by $sharers"
elif [ "$role" = implementer ] && [ -d "$wt" ]; then
  "$here/delta.sh" --state "$sdir" --out "$sdir/delta.final.patch" >/dev/null
  if [ ! -s "$sdir/delta.final.patch" ]; then
    reason="no changes"
  elif [ -f "$sdir/integrated.sha" ] && [ "$(sha256sum "$sdir/delta.final.patch" | cut -d' ' -f1)" = "$(cat "$sdir/integrated.sha")" ]; then
    reason="delta identical to the integrated patch"
  elif [ "$discard" = yes ]; then
    reason="discarded on request (patch kept at $sdir/delta.final.patch)"
  else
    echo "REFUSED: $wt holds work that was not integrated. Patch saved at $sdir/delta.final.patch." >&2
    echo "Integrate it, or re-run with --discard once the user agrees to drop it." >&2
    exit 8
  fi
  repo=$(json_get "$sdir/baseline.json" repo)
  # Safe to force: the check above proved nothing unintegrated remains, and the
  # remaining dirt is the copied checkout state and dependency copies.
  git -C "$repo" worktree remove --force "$wt"
  echo "removed worktree $wt ($reason)"
fi

set_field "$run" "$name" status cleaned
