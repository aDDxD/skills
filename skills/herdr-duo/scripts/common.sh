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
# Lead handoff: auto = pass to the other provider when the lead runs out of quota;
# codex|claude = always pass to that provider; off = the panel only warns.
: "${HERDR_DUO_LEAD_FALLBACK:=auto}"
# Optional LEAD_CODEX_MODEL / LEAD_CLAUDE_MODEL override the recorded pair.
# Leave them unset to preserve the initial lead's band automatically.
: "${HERDR_DUO_LEAD_ASTRA_MODEL:=gpt-6-astra}"
: "${HERDR_DUO_LEAD_OPUS_MODEL:=claude-opus-5-5}"
: "${HERDR_DUO_LEAD_CODEX_EFFORT:=$HERDR_DUO_SOL_EFFORT}"
: "${HERDR_DUO_LEAD_WARN_PCT:=10}"      # 5h quota left (%) at which the lead is told to prepare
: "${HERDR_DUO_LEAD_HANDOFF_PCT:=2}"    # 5h quota left (%) at which an idle lead counts as out
: "${HERDR_DUO_PANEL_INTERVAL:=5}"      # panel refresh, seconds
: "${HERDR_DUO_STATE_ROOT:=${XDG_STATE_HOME:-$HOME/.local/state}/herdr-duo}"
# Ignored dependency directories that --deps-auto may copy into worktrees.
: "${HERDR_DUO_DEPS_NAMES:=node_modules .venv venv vendor}"

die() { echo "ERROR: $*" >&2; exit 2; }

# Snapshot lead destinations once; workers keep their own base/strong routing.
lead_models() {
  HERDR_DUO_SOL_MODEL="$HERDR_DUO_SOL_MODEL" \
  HERDR_DUO_SONNET_MODEL="$HERDR_DUO_SONNET_MODEL" \
  HERDR_DUO_LEAD_ASTRA_MODEL="$HERDR_DUO_LEAD_ASTRA_MODEL" \
  HERDR_DUO_LEAD_OPUS_MODEL="$HERDR_DUO_LEAD_OPUS_MODEL" \
  HERDR_DUO_LEAD_CODEX_MODEL="${HERDR_DUO_LEAD_CODEX_MODEL:-}" \
  HERDR_DUO_LEAD_CLAUDE_MODEL="${HERDR_DUO_LEAD_CLAUDE_MODEL:-}" \
  HERDR_DUO_LEAD_CODEX_EFFORT="$HERDR_DUO_LEAD_CODEX_EFFORT" \
  python3 "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/lead-models.py" "$@"
}

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

# Lead fence. A run has exactly one lead, recorded in RUN_DIR/lead.json. After a
# handoff the previous lead may wake up again (its quota resets); every script that
# changes the run refuses to act for any pane but the current lead and the panel.
require_lead() {
  local lj="$1/lead.json" me=${HERDR_PANE_ID:-} lead panel
  [ -f "$lj" ] && [ -n "$me" ] || return 0
  lead=$(json_get "$lj" pane); panel=$(json_get "$lj" panel_pane)
  [ "$me" = "$lead" ] || [ "$me" = "$panel" ] \
    || die "this pane ($me) is no longer the lead of this run; the lead is $lead ($(json_get "$lj" name)). Stop and do not act on this run."
}

# Prints the panel's low-quota warning for the lead, if the panel raised one.
lead_warning() {
  [ -f "$1/lead.warning" ] || return 0
  echo "LEAD QUOTA LOW: $(cat "$1/lead.warning")"
  echo "  Record your next steps now (progress.sh note), then pass the lead at a safe point: handoff.sh --run $1 --reason \"quota low\""
}
