#!/usr/bin/env bash
# Record the lead's progress for the status panel and for a lead handoff.
# Everything a successor lead needs that is not in state.json lives here.
#
# Usage: progress.sh --run DIR plan TITLE...           set the checklist (keeps the status of unchanged titles)
#        progress.sh --run DIR step N todo|active|done|failed   (N is 1-based)
#        progress.sh --run DIR now TEXT                what you are doing right now
#        progress.sh --run DIR check LABEL RC SUMMARY  a check you ran, e.g. "e2e" 1 "256/268 passed"
#        progress.sh --run DIR goal JSON              checkpoint the portable goal object
#        progress.sh --run DIR note TEXT               a decision or next step, appended to handoff.md
set -euo pipefail
. "$(dirname "$(realpath "$0")")/common.sh"

run=""
[ "${1:-}" = --run ] && { run=${2:-}; shift 2; }
[ -f "$run/state.json" ] || die "usage: progress.sh --run DIR plan|step|now|check|note ..."
run=$(realpath "$run")
require_lead "$run"
cmd=${1:-}; shift || true

python3 - "$run/progress.json" "$run/handoff.md" "$cmd" "$@" <<'PY'
import datetime, fcntl, json, os, sys
path, notes, cmd, args = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
now = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")
def fail(msg):
    print("ERROR: " + msg, file=sys.stderr); sys.exit(2)
with open(path + ".lock", "w") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    p = json.load(open(path)) if os.path.exists(path) else {"steps": [], "now": "", "checks": []}
    if cmd == "plan":
        if not args: fail("plan needs at least one title")
        old = {s["title"]: s["status"] for s in p["steps"]}
        p["steps"] = [{"title": t, "status": old.get(t, "todo")} for t in args]
    elif cmd == "step":
        if len(args) != 2 or args[1] not in ("todo", "active", "done", "failed"): fail("step N todo|active|done|failed")
        i = int(args[0]) - 1
        if not 0 <= i < len(p["steps"]): fail(f"no step {args[0]}; the plan has {len(p['steps'])}")
        p["steps"][i]["status"] = args[1]
        if args[1] == "active": p["now"] = p["steps"][i]["title"]
    elif cmd == "now":
        if len(args) != 1: fail("now TEXT")
        p["now"] = args[0]
    elif cmd == "check":
        if len(args) != 3: fail("check LABEL RC SUMMARY")
        p["checks"] = ([c for c in p["checks"] if c["label"] != args[0]]
                       + [{"label": args[0], "rc": int(args[1]), "summary": args[2], "at": now}])[-6:]
    elif cmd == "goal":
        if len(args) != 1: fail("goal needs one JSON object")
        try:
            goal = json.loads(args[0])
        except json.JSONDecodeError as exc:
            fail("invalid goal JSON: " + str(exc))
        if not isinstance(goal, dict) or not isinstance(goal.get("objective"), str) or not goal["objective"].strip():
            fail("goal needs an object with a nonempty objective string")
        if goal.get("status", "active") not in ("active", "paused", "blocked", "usage_limited", "budget_limited", "complete"):
            fail("invalid goal status")
        goal.setdefault("status", "active")
        goal["updated_at"] = now
        goal_path = os.path.join(os.path.dirname(path), "goal.json")
        with open(goal_path + ".tmp", "w") as f:
            json.dump(goal, f, indent=2)
        os.replace(goal_path + ".tmp", goal_path)
    elif cmd == "note":
        if len(args) != 1: fail("note TEXT")
        with open(notes, "a") as f:
            f.write(f"- {now} {args[0]}\n")
    else:
        fail("unknown command: " + cmd)
    p["updated_at"] = now
    with open(path + ".tmp", "w") as f:
        json.dump(p, f, indent=2)
    os.replace(path + ".tmp", path)
done = sum(1 for s in p["steps"] if s["status"] == "done")
print(f"progress: {done}/{len(p['steps'])} done; now: {p['now'] or '-'}")
PY
lead_warning "$run"
