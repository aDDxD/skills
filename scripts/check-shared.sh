#!/usr/bin/env bash
# Fails when a file herdr-single shares with herdr-duo has drifted. Fix a shared file in
# herdr-duo, then run scripts/sync-shared.sh to copy it over.
set -uo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/shared-files.sh
. "$repo_root/scripts/shared-files.sh"

drift=0
for f in "${SHARED_FILES[@]}"; do
  src="$repo_root/skills/$SHARED_FROM/$f" dst="$repo_root/skills/$SHARED_TO/$f"
  if [[ ! -f "$src" || ! -f "$dst" ]]; then
    printf 'DRIFT: %s missing in %s or %s\n' "$f" "$SHARED_FROM" "$SHARED_TO" >&2
    drift=$((drift + 1))
    continue
  fi
  if ! shared_normalize "$src" | diff -u --label "$SHARED_FROM/$f (normalized)" --label "$SHARED_TO/$f" - "$dst" >&2; then
    drift=$((drift + 1))
  fi
done
if (( drift > 0 )); then
  printf 'DRIFT: %d shared file(s) differ; edit them in skills/%s and run scripts/sync-shared.sh\n' "$drift" "$SHARED_FROM" >&2
  exit 1
fi
printf 'Shared files in sync: %d\n' "${#SHARED_FILES[@]}"
