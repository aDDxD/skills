#!/usr/bin/env bash
# Copies the files herdr-single shares with herdr-duo, applying the prefix normalization
# (herdr-duo -> herdr-single, HERDR_DUO_ -> HERDR_SINGLE_). Edit shared files in herdr-duo.
#
# Usage: scripts/sync-shared.sh [--dry-run]
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/shared-files.sh
. "$repo_root/scripts/shared-files.sh"

dry=no
[ "${1:-}" != --dry-run ] || dry=yes
for f in "${SHARED_FILES[@]}"; do
  src="$repo_root/skills/$SHARED_FROM/$f" dst="$repo_root/skills/$SHARED_TO/$f"
  if [ -f "$dst" ] && shared_normalize "$src" | cmp -s - "$dst"; then
    continue
  fi
  echo "update: skills/$SHARED_TO/$f"
  [ "$dry" = yes ] && continue
  mkdir -p "$(dirname "$dst")"
  shared_normalize "$src" > "$dst.tmp"
  chmod --reference="$src" "$dst.tmp"
  mv "$dst.tmp" "$dst"
done
