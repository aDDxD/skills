#!/usr/bin/env bash
# Read-only preflight for herdr-duo. Starts no agents and changes no state.
# Prints a short report so the lead does not spend turns reading --help output.
set -u
. "$(dirname "$(realpath "$0")")/common.sh"

fail() { echo "PREFLIGHT FAIL: $*" >&2; exit 1; }

[ "${HERDR_ENV:-}" = 1 ] || fail "HERDR_ENV is not 1 in this command environment. Start the lead inside a Herdr pane; with Codex, use 'codex --no-daemon' if supported. A shared daemon started outside Herdr may not inherit the pane's HERDR_* variables. Do not set HERDR_ENV=1 manually."
for bin in herdr git python3; do
  command -v "$bin" >/dev/null 2>&1 || fail "$bin not found in PATH."
done

# Discovery only: group help (printed on stderr), never a bare `herdr` (that attaches the TUI).
kinds=$(herdr agent 2>&1 | sed -n 's/^ *kinds: //p')
has_kind() { case "|$kinds|" in *"|$1|"*) echo yes ;; *) echo no ;; esac; }

codex_ok=no; claude_ok=no
if command -v codex >/dev/null 2>&1; then
  h=$(codex --help 2>&1)
  grep -q -- '--model' <<<"$h" && grep -q -- '--config' <<<"$h" && grep -q 'danger-full-access' <<<"$h" \
    && grep -q -- '- never' <<<"$h" && codex_ok=yes
fi
if command -v claude >/dev/null 2>&1; then
  h=$(claude --help 2>&1)
  grep -q -- '--add-dir' <<<"$h" && grep -q -- '--disallowedTools' <<<"$h" && grep -q '"auto"' <<<"$h" \
    && grep -q '"dontAsk"' <<<"$h" && claude_ok=yes
fi

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

echo "herdr_env: ok  server: ${server:-unknown}"
echo "kinds: codex=$(has_kind codex) claude=$(has_kind claude)"
echo "luna (codex):   flags=$codex_ok  model=$HERDR_DUO_LUNA_MODEL effort=$HERDR_DUO_LUNA_EFFORT access=$HERDR_DUO_LUNA_ACCESS"
echo "haiku (claude): flags=$claude_ok  model=$HERDR_DUO_HAIKU_MODEL mode=$HERDR_DUO_HAIKU_MODE"
echo "config: $( [ -f "$HERDR_DUO_CONFIG" ] && echo "$HERDR_DUO_CONFIG" || echo "defaults (no $HERDR_DUO_CONFIG)" )"
echo "caller_pane: ${HERDR_PANE_ID:-unknown}  workspace: ${HERDR_WORKSPACE_ID:-unknown}  tab: ${HERDR_TAB_ID:-unknown}"
echo "live_agents:"
if [ -n "$live" ]; then printf '%s\n' "$live" | sed 's/^/  /'; else echo "  none-or-unavailable"; fi

if [ "$(has_kind codex)" = no ] && [ "$(has_kind claude)" = no ]; then
  fail "herdr advertises neither codex nor claude (advertised: ${kinds:-none})."
fi
[ "$codex_ok" = yes ] || echo "WARN: Luna unavailable or its flags were not confirmed; route work to Haiku." >&2
[ "$claude_ok" = yes ] || echo "WARN: Haiku unavailable or its flags were not confirmed; route work to Luna." >&2
exit 0
