# skills

A personal collection of agent skills. Each skill is a folder under `skills/`
with a `SKILL.md` that Claude Code and other Agent Skills clients can load.

## Skills

| Skill | Description |
|---|---|
| [herdr-duo](skills/herdr-duo) | Orchestrates development inside Herdr: delegates to Codex (Luna) and Claude Code (Haiku) in isolated worktrees, with cross-review and verified integration. |

## Install

### Option A: `npx skills` (all skills, or one)

Uses the [vercel-labs/skills](https://github.com/vercel-labs/skills) CLI:

```bash
npx skills add aDDxD/skills
npx skills add aDDxD/skills --skill herdr-duo
```

### Option B: manual, with `install.sh`

```bash
git clone https://github.com/aDDxD/skills
cd skills
./install.sh
```

`install.sh` symlinks each skill into `~/.claude/skills/<name>` and
`~/.agents/skills/<name>`. Usage:

```
install.sh [--copy] [--target claude|agents|both] [--force] [skill-name...]
```

| Option | Effect |
|---|---|
| *(none)* | Install every skill in `skills/` as a symlink into both directories. |
| `skill-name...` | Install only the named skills. An unknown name is an error. |
| `--copy` | Copy each skill directory instead of symlinking it. |
| `--target claude` / `agents` | Install into one directory only. Default is `both`. |
| `--force` | Replace an existing entry that is not this skill. A stray symlink is removed; a directory or file is moved to `<name>.bak-<timestamp>`. |

Behaviour:

- Re-running is safe. Entries that already match print `up to date` and are left alone.
- If an entry exists and is not this skill, the script refuses, changes nothing, and exits 1. Use `--force` to move it aside.
- Symlinks point into the clone, so keep the clone in place. Run `git pull` in it to update the skills.
- `--copy` makes independent copies that do not update with the repo. Switching between copy and symlink modes needs `--force`.

## Requirements for herdr-duo

- **Herdr**, with `herdr`, `git` and `python3` on `PATH`. The skill's preflight requires `HERDR_ENV=1`, so run it from a Herdr pane.
- **Codex CLI**, for the Luna implementer and reviewers.
- **Claude Code CLI**, for the Haiku implementer and reviewers.

Run `~/.agents/skills/herdr-duo/scripts/preflight.sh` to check these. It is read-only.

When using Codex as the lead, launch it **inside the Herdr pane** with
`codex --no-daemon` if `codex --help` lists that option. A shared Codex daemon
started outside Herdr may lack the pane's `HERDR_*` variables. The skill adds
this option to Codex workers and reviewers when supported. Do not manually
export `HERDR_ENV=1`: the socket and caller IDs must also come from the pane.

## Adding a skill

1. Create `skills/<name>/SKILL.md`. The frontmatter needs `name` (matching the folder name) and `description`:

   ```markdown
   ---
   name: my-skill
   description: One sentence on what the skill does and when to use it.
   ---

   # My Skill
   ...
   ```

2. Add any scripts or references the skill needs next to `SKILL.md`.
3. Run `scripts/validate.sh` to check the layout and frontmatter.
4. Install it locally with `./install.sh my-skill` and try it.

## License

MIT. See [LICENSE](LICENSE).
