#!/usr/bin/env bash
# Close a session's pane and remove its worktree, but only when nothing would be lost:
# the worktree's current delta must be exactly what integrate.sh applied (or empty).
# --discard removes it anyway; use it only when the user agreed to drop that work.
#
# Usage: cleanup.sh --run DIR --name NAME [--discard] [--keep-pane]
#        cleanup.sh --run DIR --finish [--keep-run]
#            principal only, once every session is cleaned: prints the final status, closes
#            the panel, and deletes the run directory, so no run files remain (--keep-run
#            keeps it for inspection). Global files stay: quota history and balance.json.
#        cleanup.sh --prune [--dry-run]
#            delete other runs' leftovers: finished runs, and runs whose principal pane is
#            gone and whose worktrees no longer exist. Worktrees are never deleted here.
# Exit: 0 cleaned, 8 refused because the worktree holds unintegrated work or sessions are live.
set -euo pipefail
here=$(dirname "$(realpath "$0")")
. "$here/common.sh"

run=""; name=""; discard=no; keep_pane=no; finish=no; keep_run=no; prune=no; dry=no
while [ $# -gt 0 ]; do
  case "$1" in
    --run) run=$2; shift 2 ;;
    --name) name=$2; shift 2 ;;
    --discard) discard=yes; shift ;;
    --keep-pane) keep_pane=yes; shift ;;
    --finish) finish=yes; shift ;;
    --keep-run) keep_run=yes; shift ;;
    --prune) prune=yes; shift ;;
    --dry-run) dry=yes; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done

# Remove now-empty run and worktree directories under the state root.
tidy() {
  find "$HERDR_DUO_STATE_ROOT/runs" "$HERDR_DUO_STATE_ROOT/wt" -mindepth 1 -maxdepth 1 -type d -empty -delete 2>/dev/null || true
}

if [ "$prune" = yes ]; then
  # Without a trustworthy list of live panes every run would look abandoned: abort instead.
  listing=$(herdr agent list 2>/dev/null) || die "cannot list Herdr agents; prune aborted (nothing deleted)"
  live_panes=$(printf %s "$listing" | python3 -c 'import json,sys
print(" ".join(a["pane_id"] for a in json.load(sys.stdin)["result"]["agents"]))' 2>/dev/null) \
    || die "unreadable Herdr agent list; prune aborted (nothing deleted)"
  python3 - "$HERDR_DUO_STATE_ROOT/runs" "$live_panes" "$dry" "${run:+$(realpath "$run")}" <<'PY'
import glob, json, os, shutil, sys
root, live, dry, current = sys.argv[1], set(sys.argv[2].split()), sys.argv[3] == "yes", sys.argv[4]
def load(p):
    try:
        with open(p) as f: return json.load(f)
    except (OSError, ValueError): return {}
removed = kept = 0
for run in sorted(glob.glob(os.path.join(root, "*", "*"))):
    if not os.path.isdir(run) or run == current:
        continue
    state, lead = load(os.path.join(run, "state.json")), load(os.path.join(run, "lead.json"))
    worktrees = [r.get("worktree") for k in ("workers", "reviewers") for r in state.get(k, [])
                 if r.get("role") == "implementer" and r.get("worktree") and os.path.isdir(r["worktree"])]
    lead_alive = bool(lead.get("pane")) and lead["pane"] in live
    if state.get("status") == "finished" and not worktrees or not lead_alive and not worktrees:
        print(("would delete " if dry else "deleted ") + run)
        if not dry:
            shutil.rmtree(run, ignore_errors=True)
        removed += 1
    else:
        why = "worktrees still exist: " + ", ".join(worktrees) if worktrees else "principal pane still alive"
        print(f"kept {run} ({why})")
        kept += 1
print(f"prune: {removed} run(s) {'to delete' if dry else 'deleted'}, {kept} kept")
PY
  [ "$dry" = yes ] || tidy
  exit 0
fi

[ -f "$run/state.json" ] || die "no state.json in '$run'"
run=$(realpath "$run")
if [ "$finish" = yes ]; then
  require_lead "$run"
  live=$(python3 - "$run/state.json" <<'PY'
import json, sys
with open(sys.argv[1]) as f: s = json.load(f)
import os
names = [r["name"] for k in ("workers", "reviewers") for r in s.get(k, [])
         if r.get("status") not in ("cleaned", "promoted", "escalated")
         or (r.get("role") == "implementer" and r.get("worktree") and os.path.isdir(r["worktree"]))]
print(" ".join(names))
PY
)
  if [ -n "$live" ]; then
    echo "REFUSED: sessions or worktrees still open: $live. Integrate and run cleanup.sh --name <name> for each first." >&2
    exit 8
  fi
  echo "== final status"
  "$here/status.sh" --run "$run" || true
  state_edit "$run" 'state["status"] = "finished"'
  panel=$( [ -f "$run/lead.json" ] && json_get "$run/lead.json" panel_pane || true)
  if [ -n "$panel" ]; then
    herdr pane close "$panel" >/dev/null 2>&1 && echo "closed panel $panel" || echo "panel $panel already gone"
  fi
  if [ "$keep_run" = yes ]; then
    echo "run marked finished; run directory kept: $run"
  else
    case "$run" in "$HERDR_DUO_STATE_ROOT"/runs/*) ;; *) die "refusing to delete a run outside $HERDR_DUO_STATE_ROOT/runs: $run" ;; esac
    rm -rf -- "$run"
    tidy
    echo "run finished; run directory deleted (no run files remain)"
  fi
  exit 0
fi
[ -n "$name" ] || die "--name or --finish is required"
require_owner "$run" "$name"

read -r role pane wt sdir sharers < <(python3 -c '
import json, sys
s = json.load(open(sys.argv[1]))
recs = [r for k in ("workers", "reviewers") for r in s.get(k, [])]
r = next((r for r in recs if r["name"] == sys.argv[2]), None)
if not r:
    print("- - - - -"); sys.exit()
# Other live implementers in the same worktree (a --continue-from takeover works in place).
others = [o["name"] for o in recs if o["name"] != r["name"] and o.get("role") == "implementer"
          and o.get("worktree") == r.get("worktree") and o.get("status") not in ("cleaned", "escalated", "promoted")]
print(r["role"], r.get("pane") or "-", r.get("worktree") or "-", r.get("state_dir") or "-", ",".join(others) or "-")
' "$run/state.json" "$name")
[ "$role" != "-" ] || die "no recorded session named $name in this run"

# A promoted sibling's pane is now the principal: clean its worktree, never its pane.
[ "$(record_get "$run" "$name" status)" != promoted ] || keep_pane=yes
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
