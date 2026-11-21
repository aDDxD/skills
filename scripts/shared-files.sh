# shellcheck shell=bash
# Files herdr-single shares with herdr-duo. They must stay identical after the prefix
# normalization below; check-shared.sh enforces it and sync-shared.sh copies them.
# Source it; do not execute it.

SHARED_FROM=herdr-duo
SHARED_TO=herdr-single
SHARED_FILES=(
  scripts/baseline.sh
  scripts/cleanup.sh
  scripts/delta.sh
  scripts/dispatch-all.sh
  scripts/dispatch.sh
  scripts/extract-report.py
  scripts/goal-handoff.py
  scripts/guard.sh
  scripts/install-hooks.sh
  scripts/integrate.sh
  scripts/panel.sh
  scripts/place.py
  scripts/progress.sh
)

# Prints herdr-duo's FILE as herdr-single's copy must read.
shared_normalize() {
  sed 's/herdr-duo/herdr-single/g; s/HERDR_DUO_/HERDR_SINGLE_/g; s/Herdr Duo/Herdr Single/g' "$1"
}
