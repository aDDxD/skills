#!/usr/bin/env bash
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
skills_dir="$repo_root/skills"
failures=0
skills_checked=0
shells_checked=0

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  failures=$((failures + 1))
}

if [[ ! -d "$skills_dir" ]]; then
  fail "skills/ directory is missing"
else
  while IFS= read -r -d '' skill_dir; do
    skills_checked=$((skills_checked + 1))
    dir_name="$(basename "$skill_dir")"
    skill_file="$skill_dir/SKILL.md"
    if [[ ! -f "$skill_file" ]]; then
      fail "skills/$dir_name/SKILL.md is missing"
      continue
    fi
    if ! awk -v expected="$dir_name" '
      NR == 1 { if ($0 != "---") exit 1; in_frontmatter=1; next }
      in_frontmatter && $0 == "---" { closed=1; exit }
      in_frontmatter {
        if ($0 ~ /^name:[[:space:]]*/) {
          value=$0; sub(/^name:[[:space:]]*/, "", value)
          gsub(/^[[:space:]\047"]+|[[:space:]\047"]+$/, "", value)
          name=value
        }
        if ($0 ~ /^description:[[:space:]]*/) {
          value=$0; sub(/^description:[[:space:]]*/, "", value)
          gsub(/^[[:space:]\047"]+|[[:space:]\047"]+$/, "", value)
          description=value
        }
      }
      END {
        if (!closed || name == "" || name != expected || description == "") exit 1
      }
    ' "$skill_file"; then
      fail "skills/$dir_name/SKILL.md must have YAML frontmatter with non-empty name equal to '$dir_name' and non-empty description"
    fi
  done < <(find "$skills_dir" -mindepth 1 -maxdepth 1 -type d -print0)
fi

while IFS= read -r -d '' script; do
  shells_checked=$((shells_checked + 1))
  rel_path="${script#"$repo_root/"}"
  if [[ ! -x "$script" ]]; then
    fail "$rel_path is not executable"
  fi
  if ! bash -n "$script"; then
    fail "$rel_path failed bash -n"
  fi
done < <(find "$skills_dir" -type f -name '*.sh' -print0 2>/dev/null)

if command -v shellcheck >/dev/null 2>&1; then
  while IFS= read -r -d '' script; do
    # -x follows sourced helpers; warnings and errors fail, style-level info does not.
    if ! shellcheck -x -S warning "$script"; then
      fail "$(basename "$script") failed shellcheck"
    fi
  done < <(find "$skills_dir" -type f -name '*.sh' -print0 2>/dev/null)
else
  printf 'SKIP: shellcheck not installed\n'
fi

if (( failures > 0 )); then
  printf 'Validation failed: %d failure(s), %d skill(s), %d shell script(s) checked.\n' "$failures" "$skills_checked" "$shells_checked" >&2
  exit 1
fi
printf 'Validation passed: %d skill(s), %d shell script(s) checked.\n' "$skills_checked" "$shells_checked"
