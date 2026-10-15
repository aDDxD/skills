#!/usr/bin/env bash
# Install (or remove) the herdr-duo quota guardian hook in Claude Code and Codex.
# Adds hook.py to UserPromptSubmit and PostToolUse in ~/.claude/settings.json and
# ~/.codex/hooks.json, next to any hooks already there. The hook is silent outside a
# herdr-duo run. A timestamped backup of each file is kept. Re-running is safe.
#
# Usage: install-hooks.sh [--uninstall] [--claude-only|--codex-only]
set -euo pipefail
hook="$(dirname "$(realpath "$0")")/hook.py"
mode=install; targets=(claude codex)
while [ $# -gt 0 ]; do
  case "$1" in
    --uninstall) mode=uninstall; shift ;;
    --claude-only) targets=(claude); shift ;;
    --codex-only) targets=(codex); shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

for t in "${targets[@]}"; do
  if [ "$t" = claude ]; then
    file="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"; nested=no
  else
    file="${CODEX_HOME:-$HOME/.codex}/hooks.json"; nested=yes
  fi
  [ -d "$(dirname "$file")" ] || { echo "$t: $(dirname "$file") not found, skipped"; continue; }
  [ ! -f "$file" ] || cp -p "$file" "$file.bak-herdr-duo-$(date +%s)"
  python3 - "$file" "$hook" "$mode" "$nested" "$t" <<'PY'
import json, os, shlex, sys
path, hook, mode, nested, name = sys.argv[1:]
data = json.load(open(path)) if os.path.exists(path) and os.path.getsize(path) else {}
hooks = data.setdefault("hooks", {})
command = "python3 " + shlex.quote(hook)
changed = False
for event in ("UserPromptSubmit", "PostToolUse"):
    groups = hooks.setdefault(event, [])
    kept = []
    for group in groups:
        remaining = [h for h in group.get("hooks", [])
                     if "herdr-duo/scripts/hook.py" not in h.get("command", "")]
        if remaining:
            kept.append(dict(group, hooks=remaining))
    if mode == "install":
        kept.append({"hooks": [{"type": "command", "command": command, "timeout": 10}]})
    changed |= kept != groups
    if kept:
        hooks[event] = kept
    else:
        hooks.pop(event, None)
with open(path + ".tmp", "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(path + ".tmp", path)
print(f"{name}: {'installed' if mode == 'install' else 'removed'} herdr-duo quota hook in {path}" + ("" if changed else " (no change)"))
PY
done
