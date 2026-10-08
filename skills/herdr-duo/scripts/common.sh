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
