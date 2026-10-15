# shellcheck shell=bash
# Shared helpers for herdr-duo scripts. Source it; do not execute it.
# Defaults can be overridden in ${XDG_CONFIG_HOME:-~/.config}/herdr-duo/config.env
# or through the environment of the calling shell.

HERDR_DUO_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/herdr-duo/config.env"
# shellcheck disable=SC1090
[ -f "$HERDR_DUO_CONFIG" ] && . "$HERDR_DUO_CONFIG"

# Sibling leads: one per subscription, a fixed pair. Astra is not used.
: "${HERDR_DUO_OPUS_MODEL:=${HERDR_DUO_LEAD_OPUS_MODEL:-claude-opus-5-5}}"
: "${HERDR_DUO_SOL_MODEL:=gpt-6.1-sol}"
: "${HERDR_DUO_SOL_EFFORT:=medium}"
# Effort of Sol as a lead (sibling or handoff successor); helpers that use Sol keep SOL_EFFORT.
: "${HERDR_DUO_LEAD_CODEX_EFFORT:=$HERDR_DUO_SOL_EFFORT}"
# Effort: the sibling and a handoff successor inherit the effort the principal was started
# with (recorded at run-init). The two settings above apply only when it is unknown.
# Helpers always run at HELPER_EFFORT, on both subscriptions.
: "${HERDR_DUO_HELPER_EFFORT:=xhigh}"
# Helpers: as many as the task needs, from either subscription.
: "${HERDR_DUO_LUNA_MODEL:=gpt-6-luna}"
: "${HERDR_DUO_LUNA_EFFORT:=medium}"
: "${HERDR_DUO_HAIKU_MODEL:=claude-haiku-5-5}"
# Access profiles for unattended sessions (siblings and helpers). The old LUNA_ACCESS and
# HAIKU_MODE names are still read.
: "${HERDR_DUO_CODEX_ACCESS:=${HERDR_DUO_LUNA_ACCESS:-full}}"  # full = danger-full-access + never ask; workspace = workspace-write + on-request
: "${HERDR_DUO_CLAUDE_MODE:=${HERDR_DUO_HAIKU_MODE:-auto}}"    # auto | acceptEdits | default
# Principal handoff: auto = promote the live sibling, else start the other provider's
# lead; codex|claude = always that provider; off = the panel only warns.
: "${HERDR_DUO_LEAD_FALLBACK:=auto}"
: "${HERDR_DUO_LEAD_WARN_PCT:=10}"      # 5h quota left (%) at which a lead is told to checkpoint
: "${HERDR_DUO_LEAD_HANDOFF_PCT:=2}"    # 5h quota left (%) at which an idle lead counts as out
: "${HERDR_DUO_LEAD_RESERVE_PCT:=30}"   # a lead's own pool below this is not suggested for helpers
: "${HERDR_DUO_PANEL_INTERVAL:=5}"      # panel refresh, seconds
: "${HERDR_DUO_STATE_ROOT:=${XDG_STATE_HOME:-$HOME/.local/state}/herdr-duo}"
# Ignored dependency directories that --deps-auto may copy into worktrees.
: "${HERDR_DUO_DEPS_NAMES:=node_modules .venv venv vendor}"
export HERDR_DUO_STATE_ROOT HERDR_DUO_LEAD_RESERVE_PCT

die() { echo "ERROR: $*" >&2; exit 2; }

HERDR_DUO_SCRIPTS="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"

# Lead pair snapshot and model detection.
lead_models() {
  HERDR_DUO_OPUS_MODEL="$HERDR_DUO_OPUS_MODEL" HERDR_DUO_SOL_MODEL="$HERDR_DUO_SOL_MODEL" \
  HERDR_DUO_SOL_EFFORT="$HERDR_DUO_LEAD_CODEX_EFFORT" \
  python3 "$HERDR_DUO_SCRIPTS/lead-models.py" "$@"
}

# Both subscriptions' 5h quota (see quota.py).
quota() { python3 "$HERDR_DUO_SCRIPTS/quota.py" "$@"; }

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

# Who is calling, from HERDR_PANE_ID: "lead" (the principal), the live sibling's name,
# "panel", or "outsider". Outside Herdr (no pane id) the caller counts as the principal.
member() {
  local run=$1 me=${HERDR_PANE_ID:-}
  if [ -z "$me" ] || [ ! -f "$run/lead.json" ]; then echo lead; return; fi
  python3 "$HERDR_DUO_SCRIPTS/members.py" whoami "$run" "$me"
}

# Lead fence. A run has one principal (lead.json) and at most one live sibling lead.
# After a handoff a previous lead may wake up again; every script that changes the run
# refuses outsiders. require_lead admits only the principal and the panel.
require_member() {
  [ "$(member "$1")" != outsider ] \
    || die "this pane (${HERDR_PANE_ID:-}) is not a lead of this run; the principal is $(json_get "$1/lead.json" pane) ($(json_get "$1/lead.json" name)). Stop and do not act on this run."
}
require_lead() {
  local who; who=$(member "$1")
  case "$who" in
    lead|panel) ;;
    outsider) require_member "$1" ;;
    *) die "only the principal lead may do this; you are the sibling '$who'. Report to the principal instead." ;;
  esac
}

# A sibling acts only on the sessions it opened (and on itself); the principal and the
# panel act on all.
require_owner() {
  local run=$1 name=$2 who owner
  who=$(member "$run")
  case "$who" in
    lead|panel) return 0 ;;
    outsider) require_member "$run" ;;
  esac
  owner=$(record_get "$run" "$name" owner)
  [ "$owner" = "$who" ] || [ "$name" = "$who" ] \
    || die "session '$name' belongs to '${owner:-lead}', not to you ('$who')"
}

# Prints the caller's low-quota warning and, for the principal, unread alerts.
lead_warning() {
  local who f
  who=$(member "$1")
  f="$1/lead.warning"
  [ "$who" = lead ] || f="$1/$who.warning"
  if [ -f "$f" ]; then
    echo "QUOTA LOW: $(cat "$f")"
    if [ "$who" = lead ]; then
      echo "  Checkpoint now (progress.sh note), then pass the principal role at a safe point: handoff.sh --run $1 --reason \"quota low\""
    else
      echo "  Checkpoint now: stop at a safe point and send the principal your report block with STATUS: partial."
    fi
  fi
  if [ "$who" = lead ] && [ -s "$1/alerts.log" ]; then
    echo "ALERTS:"
    sed 's/^/  /' "$1/alerts.log"
  fi
  return 0
}
