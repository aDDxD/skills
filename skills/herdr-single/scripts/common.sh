# shellcheck shell=bash
# Shared helpers for herdr-single scripts. Source it; do not execute it.
# Defaults can be overridden in ${XDG_CONFIG_HOME:-~/.config}/herdr-single/config.env
# or through the environment of the calling shell.

HERDR_SINGLE_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/herdr-single/config.env"
# shellcheck disable=SC1090
[ -f "$HERDR_SINGLE_CONFIG" ] && . "$HERDR_SINGLE_CONFIG"

# One subscription per run. Empty = the provider of the pane that starts the run.
: "${HERDR_SINGLE_PROVIDER:=}"
# Models per provider. The lead model is also the model of a fresh successor lead.
: "${HERDR_SINGLE_CLAUDE_LEAD_MODEL:=claude-opus-5-5}"
: "${HERDR_SINGLE_CLAUDE_HELPER_MODEL:=claude-haiku-5-5}"
: "${HERDR_SINGLE_CLAUDE_REVIEWER_MODEL:=claude-sonnet-5-5}"
: "${HERDR_SINGLE_CODEX_LEAD_MODEL:=gpt-6.1-sol}"
: "${HERDR_SINGLE_CODEX_HELPER_MODEL:=gpt-6-luna}"
: "${HERDR_SINGLE_CODEX_REVIEWER_MODEL:=gpt-6.1-sol}"
# A successor lead inherits the effort the lead was started with (recorded at run-init);
# this applies to a Codex successor only when that effort is unknown.
: "${HERDR_SINGLE_CODEX_LEAD_EFFORT:=medium}"
# Helpers and reviewers always run at this effort.
: "${HERDR_SINGLE_HELPER_EFFORT:=xhigh}"
# Access profiles for unattended sessions (helpers and successor leads).
: "${HERDR_SINGLE_CODEX_ACCESS:=full}"   # full = danger-full-access + never ask; workspace = workspace-write + on-request
: "${HERDR_SINGLE_CLAUDE_MODE:=auto}"    # auto | acceptEdits | default
# Lead continuity when its 5h window runs out: auto = park the run, then at the reset
# resume the same pane if it is alive (else start a fresh lead); fresh = always start a
# fresh lead at the reset; off = the panel only warns.
: "${HERDR_SINGLE_LEAD_RESUME:=auto}"
: "${HERDR_SINGLE_LEAD_WARN_PCT:=10}"      # 5h quota left (%) at which the lead is told to checkpoint
: "${HERDR_SINGLE_LEAD_HANDOFF_PCT:=2}"    # 5h quota left (%) at which an idle lead counts as out
: "${HERDR_SINGLE_LEAD_RESERVE_PCT:=30}"   # below this, the window is kept for the lead: no new helpers
: "${HERDR_SINGLE_MAX_HELPERS:=6}"         # ceiling of live helpers quota.py ever suggests
: "${HERDR_SINGLE_PANEL_INTERVAL:=5}"      # panel refresh, seconds
: "${HERDR_SINGLE_STATE_ROOT:=${XDG_STATE_HOME:-$HOME/.local/state}/herdr-single}"
# Ignored dependency directories that --deps-auto may copy into worktrees.
: "${HERDR_SINGLE_DEPS_NAMES:=node_modules .venv venv vendor}"
export HERDR_SINGLE_STATE_ROOT HERDR_SINGLE_LEAD_RESERVE_PCT HERDR_SINGLE_MAX_HELPERS HERDR_SINGLE_LEAD_RESUME

die() { echo "ERROR: $*" >&2; exit 2; }

HERDR_SINGLE_SCRIPTS="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"

# model_for PROVIDER lead|helper|reviewer -> the configured model.
model_for() {
  case "$1:$2" in
    claude:lead) echo "$HERDR_SINGLE_CLAUDE_LEAD_MODEL" ;;
    claude:helper) echo "$HERDR_SINGLE_CLAUDE_HELPER_MODEL" ;;
    claude:reviewer) echo "$HERDR_SINGLE_CLAUDE_REVIEWER_MODEL" ;;
    codex:lead) echo "$HERDR_SINGLE_CODEX_LEAD_MODEL" ;;
    codex:helper) echo "$HERDR_SINGLE_CODEX_HELPER_MODEL" ;;
    codex:reviewer) echo "$HERDR_SINGLE_CODEX_REVIEWER_MODEL" ;;
    *) die "model_for: unknown provider or role '$1:$2'" ;;
  esac
}

# Lead model and effort detection (see lead-models.py).
lead_models() {
  HERDR_SINGLE_CLAUDE_LEAD_MODEL="$HERDR_SINGLE_CLAUDE_LEAD_MODEL" \
  HERDR_SINGLE_CODEX_LEAD_MODEL="$HERDR_SINGLE_CODEX_LEAD_MODEL" \
  HERDR_SINGLE_CODEX_LEAD_EFFORT="$HERDR_SINGLE_CODEX_LEAD_EFFORT" \
  python3 "$HERDR_SINGLE_SCRIPTS/lead-models.py" "$@"
}

# The run's 5h quota (see quota.py). Pass --provider to read one subscription only.
quota() { python3 "$HERDR_SINGLE_SCRIPTS/quota.py" "$@"; }

# json_get FILE KEY -> prints the value of a top-level key ("" if missing).
json_get() {
  python3 - "$1" "$2" <<'PY'
import json, sys
v = json.load(open(sys.argv[1])).get(sys.argv[2])
print("" if v is None else (json.dumps(v) if isinstance(v, (list, dict)) else v))
PY
}

# run_provider RUN_DIR -> the subscription this run is fixed to.
run_provider() { json_get "$1/state.json" provider; }

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

# Who is calling, from HERDR_PANE_ID: "lead", "panel", or "outsider". Outside Herdr
# (no pane id) the caller counts as the lead.
member() {
  local run=$1 me=${HERDR_PANE_ID:-}
  if [ -z "$me" ] || [ ! -f "$run/lead.json" ]; then echo lead; return; fi
  python3 "$HERDR_SINGLE_SCRIPTS/members.py" whoami "$run" "$me"
}

# Lead fence. A run has one lead (lead.json). After a handoff a previous lead may wake up
# again; every script that changes the run refuses outsiders.
require_member() {
  [ "$(member "$1")" != outsider ] \
    || die "this pane (${HERDR_PANE_ID:-}) is not the lead of this run; the lead is $(json_get "$1/lead.json" pane) ($(json_get "$1/lead.json" name)). Stop and do not act on this run."
}
require_lead() { require_member "$1"; }
# Every session of a single run belongs to the lead.
require_owner() { require_member "$1"; }

# Prints the lead's low-quota warning and unread alerts.
lead_warning() {
  local f="$1/lead.warning"
  [ "$(member "$1")" = lead ] || return 0
  if [ -f "$f" ]; then
    echo "QUOTA LOW: $(cat "$f")"
    echo "  Checkpoint now (progress.sh note) and bring your work to a safe point. At the window's reset the panel resumes the run; nothing else is open to take over."
  fi
  if [ -s "$1/alerts.log" ]; then
    echo "ALERTS:"
    sed 's/^/  /' "$1/alerts.log"
  fi
  return 0
}
