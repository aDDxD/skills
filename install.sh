#!/usr/bin/env bash
# Install the skills in this repository into Claude Code and the Agent Skills directory.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: install.sh [--copy] [--target claude|agents|both] [--force] [skill-name...]

Installs every skill in skills/ (or only the named ones) into:
  claude   ~/.claude/skills/<name>
  agents   ~/.agents/skills/<name>

Options:
  --copy            copy each skill directory instead of symlinking it
  --target TARGET   claude, agents or both (default: both)
  --force           replace an existing entry that does not match this repo;
                    the old entry is moved to <name>.bak-<timestamp>
  -h, --help        show this help

Re-running is safe: entries that already match are left alone. If any entry
conflicts and --force is not given, nothing is changed and the script exits 1.
EOF
}

die() { echo "install.sh: $*" >&2; exit 1; }

copy_mode=0
target=both
force=0
names=()

while [ $# -gt 0 ]; do
  case "$1" in
    --copy) copy_mode=1; shift ;;
    --target) [ $# -ge 2 ] || die "--target needs a value"; target="$2"; shift 2 ;;
    --target=*) target="${1#--target=}"; shift ;;
    --force) force=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option: $1 (see --help)" ;;
    *) names+=("$1"); shift ;;
  esac
done

case "$target" in
  claude) roots=("$HOME/.claude/skills") ;;
  agents) roots=("$HOME/.agents/skills") ;;
  both)   roots=("$HOME/.claude/skills" "$HOME/.agents/skills") ;;
  *) die "--target must be claude, agents or both (got: $target)" ;;
esac

repo="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
src_root="$repo/skills"

available=()
for dir in "$src_root"/*/; do
  if [ -f "$dir/SKILL.md" ]; then
    available+=("$(basename "$dir")")
  fi
done
[ ${#available[@]} -gt 0 ] || die "no skills found in $src_root"

selected=()
if [ ${#names[@]} -gt 0 ]; then
  for name in "${names[@]}"; do
    found=0
    for a in "${available[@]}"; do
      if [ "$a" = "$name" ]; then found=1; fi
    done
    [ "$found" -eq 1 ] || die "unknown skill: $name (available: ${available[*]})"
    selected+=("$name")
  done
else
  selected=("${available[@]}")
fi

exists() { [ -e "$1" ] || [ -L "$1" ]; }

# Prints "match" if <dest> already is this skill, "missing" if nothing is there,
# and "conflict" for anything else. In link mode a match is a symlink to <src>;
# in copy mode a match is a directory with identical contents.
state_of() {
  local src="$1" dest="$2"
  if [ "$copy_mode" -eq 1 ]; then
    if [ -L "$dest" ]; then echo conflict
    elif [ -d "$dest" ]; then
      if diff -rq "$src" "$dest" >/dev/null 2>&1; then echo match; else echo conflict; fi
    elif exists "$dest"; then echo conflict
    else echo missing; fi
  else
    if [ -L "$dest" ] && [ "$(readlink "$dest")" = "$src" ]; then echo match
    elif exists "$dest"; then echo conflict
    else echo missing; fi
  fi
}

# Check everything before touching anything, so a refusal leaves no partial install.
plan_src=()
plan_dest=()
plan_state=()
conflicts=0
for root in "${roots[@]}"; do
  for name in "${selected[@]}"; do
    src="$src_root/$name"
    dest="$root/$name"
    st="$(state_of "$src" "$dest")"
    if [ "$st" = conflict ] && [ "$force" -eq 0 ]; then
      echo "conflict: $dest exists and is not this skill" >&2
      conflicts=$((conflicts + 1))
    fi
    plan_src+=("$src")
    plan_dest+=("$dest")
    plan_state+=("$st")
  done
done
if [ "$conflicts" -gt 0 ]; then
  die "$conflicts conflict(s); nothing was changed. Re-run with --force to move them aside."
fi

for i in "${!plan_dest[@]}"; do
  src="${plan_src[$i]}"
  dest="${plan_dest[$i]}"
  case "${plan_state[$i]}" in
    match)
      echo "up to date: $dest"
      continue
      ;;
    conflict)
      if [ -L "$dest" ]; then
        rm -- "$dest"
        echo "removed symlink: $dest"
      else
        bak="$dest.bak-$(date +%Y%m%d%H%M%S)"
        mv -- "$dest" "$bak"
        echo "moved aside: $dest -> $bak"
      fi
      ;;
  esac
  mkdir -p -- "$(dirname -- "$dest")"
  if [ "$copy_mode" -eq 1 ]; then
    cp -R -- "$src" "$dest"
    echo "copied: $src -> $dest"
  else
    ln -s -- "$src" "$dest"
    echo "linked: $dest -> $src"
  fi
done

if [ "$copy_mode" -eq 0 ]; then
  echo "Symlinks point into $repo; keep this clone where it is."
fi
