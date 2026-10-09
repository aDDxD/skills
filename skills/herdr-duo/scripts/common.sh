# shellcheck shell=bash
# Shared helpers for herdr-duo scripts. Source it; do not execute it.
# Defaults can be overridden in ${XDG_CONFIG_HOME:-~/.config}/herdr-duo/config.env
# or through the environment of the calling shell.

HERDR_DUO_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/herdr-duo/config.env"
# shellcheck disable=SC1090
[ -f "$HERDR_DUO_CONFIG" ] && . "$HERDR_DUO_CONFIG"

: "${HERDR_DUO_LUNA_MODEL:=gpt-6-luna}"
: "${HERDR_DUO_LUNA_EFFORT:=medium}"
: "${HERDR_DUO_LUNA_ACCESS:=full}"        # full = danger-full-access + never ask; workspace = workspace-write + on-request
: "${HERDR_DUO_HAIKU_MODEL:=claude-haiku-5-5}"
: "${HERDR_DUO_HAIKU_MODE:=auto}"         # auto | acceptEdits | default
# Strong tier, only for escalations and cross-cutting tasks; one live session at a time.
: "${HERDR_DUO_SOL_MODEL:=gpt-6.1-sol}"
: "${HERDR_DUO_SOL_EFFORT:=high}"
: "${HERDR_DUO_SONNET_MODEL:=claude-sonnet-5-5}"
: "${HERDR_DUO_STATE_ROOT:=${XDG_STATE_HOME:-$HOME/.local/state}/herdr-duo}"
# Ignored dependency directories that --deps-auto may copy into worktrees.
: "${HERDR_DUO_DEPS_NAMES:=node_modules .venv venv vendor}"

die() { echo "ERROR: $*" >&2; exit 2; }

# json_get FILE KEY -> prints the value of a top-level key ("" if missing).
json_get() {
  python3 - "$1" "$2" <<'PY'
import json, sys
v = json.load(open(sys.argv[1])).get(sys.argv[2])
print("" if v is None else (json.dumps(v) if isinstance(v, (list, dict)) else v))
PY
}

# Basenames of files that must never be copied into a worker worktree.
is_secret_path() {
  case "$(basename "$1")" in
    .env|.env.*|.dev.vars|*.pem|*.key|*.p12|*.pfx|id_rsa*|id_ed25519*|*credential*|*secret*|.npmrc|.pypirc|.netrc)
      return 0 ;;
  esac
  return 1
}

# First line of a trust/selection dialog visible in PANE, or nothing.
# Herdr can report a Codex pane as idle while its folder-trust dialog is open, so
# never type into a pane before this returns empty: Enter would answer the dialog.
pane_dialog() {
  herdr pane read "$1" --source visible 2>/dev/null | python3 -c '
import re, sys
pat = re.compile(r"trust this folder|do you trust|quick safety check|folder access|trust and continue|"
                 r"enter to confirm|esc to cancel|enter continue|esc quit", re.I)
for line in sys.stdin:
    if pat.search(line):
        print(line.strip()); break
'
}

# Herdr lifecycle state (idle|working|blocked|done|unknown) of an agent name or pane id.
agent_status() {
  herdr agent get "$1" 2>/dev/null | python3 -c '
import json, sys
def find(o):
    if isinstance(o, dict):
        if "agent_status" in o: return o["agent_status"]
        for v in o.values():
            r = find(v)
            if r: return r
    elif isinstance(o, list):
        for v in o:
            r = find(v)
            if r: return r
    return ""
try: print(find(json.load(sys.stdin)))
except Exception: print("")
'
}

# Pathspecs that exclude the recorded dependency directories from git add.
# Usage: deps_excludes BASELINE_JSON -> one pathspec per line.
deps_excludes() {
  python3 - "$1" <<'PY'
import json, sys
for d in json.load(open(sys.argv[1])).get("deps", []):
    if d.get("exclude", True):
        print(":(exclude)" + d["path"])
PY
}

# Name of the live strong-tier session in RUN_DIR/state.json, or nothing.
# Sessions marked cleaned or escalated no longer hold a pane.
live_strong() {
  python3 - "$1/state.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
for k in ("workers", "reviewers"):
    for r in s.get(k, []):
        if r.get("tier") == "strong" and r.get("status") not in ("cleaned", "escalated"):
            print(r["name"]); sys.exit(0)
PY
}

# record_get RUN_DIR NAME KEY -> prints one field of a session record ("" if missing).
record_get() {
  python3 - "$1/state.json" "$2" "$3" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
r = next((r for k in ("workers", "reviewers") for r in s.get(k, []) if r.get("name") == sys.argv[2]), {})
v = r.get(sys.argv[3])
print("" if v is None else v)
PY
}

# state_edit RUN_DIR PYCODE [ARG...] -> runs PYCODE with `state` (the parsed state.json)
# and `args`, under an exclusive lock, then writes state.json atomically. Parallel
# dispatches and spawns update the same file, so every writer goes through here.
state_edit() {
  local run=$1 code=$2; shift 2
  python3 - "$run/state.json" "$code" "$@" <<'PY'
import fcntl, json, os, sys
path, code, args = sys.argv[1], sys.argv[2], sys.argv[3:]
with open(path + ".lock", "w") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    state = json.load(open(path))
    exec(code, {"state": state, "args": args, "json": json})
    with open(path + ".tmp", "w") as f:
        json.dump(state, f, indent=2)
    os.replace(path + ".tmp", path)
PY
}

# set_field RUN_DIR NAME KEY VALUE -> sets one field of a session record.
# VALUE is stored as JSON when it parses as JSON (numbers), otherwise as a string.
set_field() {
  state_edit "$1" '
name, key, value = args
try: value = json.loads(value)
except ValueError: pass
for k in ("workers", "reviewers"):
    for r in state.get(k, []):
        if r.get("name") == name:
            r[key] = value
' "$2" "$3" "$4"
}
