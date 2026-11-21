#!/usr/bin/env bash
# Read-only preflight for herdr-single. Starts no agents and changes no state.
# Finds the run's subscription (HERDR_SINGLE_PROVIDER, --provider, or the calling pane's
# agent) and checks only that CLI: the other subscription may be absent or logged out.
#
# Usage: preflight.sh [--provider codex|claude]
set -u
. "$(dirname "$(realpath "$0")")/common.sh"

fail() { echo "PREFLIGHT FAIL: $*" >&2; exit 1; }

provider=$HERDR_SINGLE_PROVIDER
[ "${1:-}" != --provider ] || provider=${2:-}

[ "${HERDR_ENV:-}" = 1 ] || fail "HERDR_ENV is not 1 in this command environment. Start the lead inside a Herdr pane; with Codex, use 'codex --no-daemon' if supported. A shared daemon started outside Herdr may not inherit the pane's HERDR_* variables. Do not set HERDR_ENV=1 manually."
for bin in herdr git python3; do
  command -v "$bin" >/dev/null 2>&1 || fail "$bin not found in PATH."
done

detected=""
if [ -n "${HERDR_PANE_ID:-}" ]; then
  detected=$(herdr agent get "$HERDR_PANE_ID" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["agent"].get("agent") or "")' 2>/dev/null || true)
fi
source="configured"
if [ -z "$provider" ]; then provider=$detected; source="this pane's agent"; fi
case "$provider" in
  codex|claude) ;;
  "") fail "cannot tell which subscription this run uses: this pane's agent is unknown. Pass --provider codex|claude to preflight.sh and run-init.sh, or set HERDR_SINGLE_PROVIDER." ;;
  *) fail "provider must be codex or claude, not '$provider'." ;;
esac

# Discovery only: group help (printed on stderr), never a bare `herdr` (that attaches the TUI).
kinds=$(herdr agent 2>&1 | sed -n 's/^ *kinds: //p')
case "|$kinds|" in *"|$provider|"*) ;; *) fail "herdr does not advertise the $provider agent kind (advertised: ${kinds:-none})." ;; esac

command -v "$provider" >/dev/null 2>&1 || fail "$provider CLI not found in PATH."
h=$("$provider" --help 2>&1)
flags=no
if [ "$provider" = codex ]; then
  grep -q -- '--model' <<<"$h" && grep -q -- '--config' <<<"$h" && grep -q 'danger-full-access' <<<"$h" \
    && grep -q -- '- never' <<<"$h" && flags=yes
else
  grep -q -- '--add-dir' <<<"$h" && grep -q -- '--disallowedTools' <<<"$h" && grep -q '"auto"' <<<"$h" \
    && grep -q '"dontAsk"' <<<"$h" && flags=yes
fi
[ "$flags" = yes ] || fail "the $provider CLI does not list the flags herdr-single needs (see spawn.sh access profiles); update it."

server=$(herdr status server 2>&1 | head -n 1)
live=$(timeout 10 herdr agent list 2>/dev/null | python3 -c '
import json, sys
try:
    agents = json.load(sys.stdin)["result"]["agents"]
except Exception:
    agents = []
for a in agents:
    print(a.get("agent"), ":", a.get("agent_status"), " @", a.get("pane_id"), " cwd=", a.get("cwd"), sep="")
' 2>/dev/null)

if [ "$provider" = codex ]; then access="access=$HERDR_SINGLE_CODEX_ACCESS"; else access="mode=$HERDR_SINGLE_CLAUDE_MODE"; fi
echo "herdr_env: ok  server: ${server:-unknown}"
echo "provider: $provider ($source)  flags=ok  $access"
echo "models: lead=$(model_for "$provider" lead) helper=$(model_for "$provider" helper) reviewer=$(model_for "$provider" reviewer)"
[ -z "$detected" ] || [ "$detected" = "$provider" ] \
  || echo "WARN: this pane runs $detected but the run is set to $provider; helpers and successors use $provider." >&2
quota line --provider "$provider" 2>/dev/null || echo "5h quota: unavailable"
hooks=no
if [ "$provider" = claude ]; then
  grep -q 'herdr-single/scripts/hook.py' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" 2>/dev/null && hooks=yes
else
  grep -q 'herdr-single/scripts/hook.py' "${CODEX_HOME:-$HOME/.codex}/hooks.json" 2>/dev/null && hooks=yes
fi
echo "quota hook ($provider): $hooks  (install: $(dirname "$(realpath "$0")")/install-hooks.sh --$provider-only)"
echo "lead resume: $HERDR_SINGLE_LEAD_RESUME"
echo "config: $( [ -f "$HERDR_SINGLE_CONFIG" ] && echo "$HERDR_SINGLE_CONFIG" || echo "defaults (no $HERDR_SINGLE_CONFIG)" )"
echo "caller_pane: ${HERDR_PANE_ID:-unknown}  workspace: ${HERDR_WORKSPACE_ID:-unknown}  tab: ${HERDR_TAB_ID:-unknown}"
echo "live_agents:"
if [ -n "$live" ]; then printf '%s\n' "$live" | sed 's/^/  /'; else echo "  none-or-unavailable"; fi
exit 0
