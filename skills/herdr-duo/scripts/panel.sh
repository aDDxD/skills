#!/usr/bin/env bash
# Run the status panel and lead watchdog for a run (panel.py) with this skill's config.
# run-init.sh starts it in its own pane; run it by hand only to restore a closed panel:
#   herdr pane run <pane> "<skill>/scripts/panel.sh --run <RUN>"
set -euo pipefail
here=$(dirname "$(realpath "$0")")
. "$here/common.sh"
[ "${1:-}" = --run ] && [ -f "${2:-}/state.json" ] || die "usage: panel.sh --run DIR"
export HERDR_DUO_PANEL_INTERVAL HERDR_DUO_LEAD_WARN_PCT HERDR_DUO_LEAD_HANDOFF_PCT
[ -z "${HERDR_DUO_LIMIT_REGEX:-}" ] || export HERDR_DUO_LIMIT_REGEX
exec python3 "$here/panel.py" "$(realpath "$2")"
