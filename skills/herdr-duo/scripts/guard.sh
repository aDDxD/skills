#!/usr/bin/env bash
# Detect git-state changes that workers must not make. With full-access workers the
# sandbox no longer prevents them, so the lead snapshots before dispatch and verifies
# after every settle and before integration or commit.
#
# Usage: guard.sh snapshot --run DIR
#        guard.sh verify   --run DIR      exit 4 = violation found
# Watches: repository HEAD and branch, every ref (branches, tags, remote-tracking refs
# updated by a push, stash), local git config, and each implementer worktree staying
# detached at its baseline commit.
set -euo pipefail
. "$(dirname "$(realpath "$0")")/common.sh"

mode=${1:-}; shift || true
run=""
while [ $# -gt 0 ]; do
  case "$1" in
    --run) run=$2; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ "$mode" = snapshot ] || [ "$mode" = verify ] || die "usage: guard.sh snapshot|verify --run DIR"
[ -f "$run/state.json" ] || die "no state.json in $run"
require_lead "$run"

capture() {
  python3 - "$run/state.json" <<'PY'
import json, subprocess, sys, hashlib, os

def git(*args, cwd):
    r = subprocess.run(["git", "-C", cwd, *args], capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else ""

state = json.load(open(sys.argv[1]))
repo = state["repo"]
common = git("rev-parse", "--git-common-dir", cwd=repo)
common = common if os.path.isabs(common) else os.path.join(repo, common)
config_path = os.path.join(common, "config")
snap = {
    "head": git("rev-parse", "HEAD", cwd=repo),
    "branch": git("symbolic-ref", "-q", "HEAD", cwd=repo),
    "refs": dict(line.split(" ", 1)[::-1] for line in
                 git("for-each-ref", "--format=%(objectname) %(refname)", cwd=repo).splitlines() if line),
    "config_sha": hashlib.sha256(open(config_path, "rb").read()).hexdigest() if os.path.exists(config_path) else "",
    "worktrees": {},
}
for w in state.get("workers", []):
    wt = w.get("worktree")
    bj = os.path.join(w.get("state_dir", ""), "baseline.json")
    # Cleaned worktrees are gone, and an escalated one is checked under its successor.
    if not wt or not os.path.isdir(wt) or not os.path.exists(bj) or w.get("status") in ("cleaned", "escalated"):
        continue
    snap["worktrees"][w["name"]] = {
        "path": wt,
        "expected_head": json.load(open(bj))["head"],
        "head": git("rev-parse", "HEAD", cwd=wt),
        "branch": git("symbolic-ref", "-q", "HEAD", cwd=wt),
    }
print(json.dumps(snap, indent=2, sort_keys=True))
PY
}

if [ "$mode" = snapshot ]; then
  capture > "$run/guard.json"
  echo "guard snapshot saved: $run/guard.json"
  exit 0
fi

[ -f "$run/guard.json" ] || die "no guard snapshot; run guard.sh snapshot first"
capture > "$run/guard.now.json"
python3 - "$run/guard.json" "$run/guard.now.json" <<'PY'
import json, sys
old, new = (json.load(open(p)) for p in sys.argv[1:3])
problems = []
if old["head"] != new["head"] or old["branch"] != new["branch"]:
    problems.append(f"repository HEAD/branch changed: {old['branch'] or 'detached'}@{old['head'][:12]} -> {new['branch'] or 'detached'}@{new['head'][:12]} (a worker or the user)")
for ref in sorted(set(old["refs"]) | set(new["refs"])):
    a, b = old["refs"].get(ref), new["refs"].get(ref)
    if a != b:
        what = "created" if a is None else "deleted" if b is None else "moved"
        hint = " (looks like a push)" if ref.startswith("refs/remotes/") else ""
        problems.append(f"ref {what}: {ref}{hint}")
if old["config_sha"] != new["config_sha"]:
    problems.append("repository git config changed")
for name, w in new["worktrees"].items():
    if w["branch"]:
        problems.append(f"worker {name}: worktree switched to branch {w['branch']}")
    if w["head"] != w["expected_head"]:
        problems.append(f"worker {name}: worktree HEAD moved from baseline {w['expected_head'][:12]} to {w['head'][:12]} (commit or checkout)")
if problems:
    print("GUARD VIOLATION:")
    for p in problems:
        print("  - " + p)
    sys.exit(4)
print("guard ok: no ref, HEAD, branch or config changes")
PY
