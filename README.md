# skills

A personal collection of agent skills. Each skill is a folder under `skills/`
with a `SKILL.md` that Claude Code and other Agent Skills clients can load.

## Skills

| Skill | Description |
|---|---|
| [herdr-duo](skills/herdr-duo) | Runs one task across your Claude and Codex subscriptions inside Herdr: the lead you start (Opus or Sol) does the main work, hands a separable slice to its sibling lead on the other subscription so both 5-hour windows are used evenly, and both leads open as many Luna/Haiku helpers as the task can use. Keeps a quota and progress panel, automatic lead handoff, isolated worktrees, cross-review and verified integration. |
| [herdr-single](skills/herdr-single) | The same orchestration on one subscription, Claude only or Codex only: the lead you start does the main work and opens helpers and reviewers of that subscription, paced by its 5-hour window. Keeps the progress and quota panel, isolated worktrees, independent same-subscription review and verified integration; when the window runs out the run parks and resumes at the reset. |

## Install

### Option A: `npx skills` (all skills, or one)

Uses the [vercel-labs/skills](https://github.com/vercel-labs/skills) CLI:

```bash
npx skills add aDDxD/skills
npx skills add aDDxD/skills --skill herdr-duo
npx skills add aDDxD/skills --skill herdr-single
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
- **Codex CLI**, for Codex implementers and reviewers.
- **Claude Code CLI**, for Claude implementers and reviewers.
- The lead pair is fixed: **Opus** (Claude) and **Sol** (Codex), set with `HERDR_DUO_OPUS_MODEL` and `HERDR_DUO_SOL_MODEL` in `~/.config/herdr-duo/config.env`. Astra is not used. The pair is the sibling lead and the handoff destination. Helpers default to Luna and Haiku (`HERDR_DUO_LUNA_MODEL`, `HERDR_DUO_HAIKU_MODEL`); a lead can choose any model per helper.
- Effort parity: the sibling lead and any handoff successor run at the effort you started the principal with; Luna and Haiku helpers always run at `xhigh` (`HERDR_DUO_HELPER_EFFORT`).
- No run files are left behind: `cleanup.sh --run <RUN> --finish` deletes the run directory once every session is cleaned, and `cleanup.sh --prune` removes leftovers of abandoned runs.
- Only the 5-hour windows count; weekly quota is ignored. Claude's window is read from the Herdr usage bar (`~/.claude/herdr-usagebar/claude-limits-latest.json`) and Codex's from its newest session rollout, so both are known without an open pane. `scripts/quota.py line` prints them with the projected unused share at reset.
- Each run opens a status panel next to the lead with progress, both windows, both leads and their helpers. When the principal lead runs out, a live sibling is promoted; otherwise a fresh lead of the pair starts. A provider that ran out waits for its real reset. Set `HERDR_DUO_LEAD_FALLBACK=off` to only warn.
- Optional: `~/.agents/skills/herdr-duo/scripts/install-hooks.sh` adds a quota guardian hook to Claude Code and Codex (UserPromptSubmit and PostToolUse). It is silent outside a herdr-duo run, and gives each lead the quota line and low-quota warnings even during long turns. `--uninstall` removes it.

Run `~/.agents/skills/herdr-duo/scripts/preflight.sh` to check these. It is read-only.

When using Codex as the lead, launch it **inside the Herdr pane** with
`codex --no-daemon` if `codex --help` lists that option. A shared Codex daemon
started outside Herdr may lack the pane's `HERDR_*` variables. The skill adds
this option to Codex workers and reviewers when supported. Do not manually
export `HERDR_ENV=1`: the socket and caller IDs must also come from the pane.

## Requirements for herdr-single

- **Herdr**, with `herdr`, `git` and `python3` on `PATH`, run from a Herdr pane (`HERDR_ENV=1`), as for herdr-duo.
- **One** of the Claude Code CLI or the Codex CLI. A run uses only the subscription of the lead that starts it (detected from the pane, or `run-init.sh --provider codex|claude`); `spawn.sh` and handoffs refuse the other one, so it may be logged out or not installed.
- Models per provider, set in `~/.config/herdr-single/config.env`:

  | Role | Claude | Codex |
  |---|---|---|
  | Lead and successor lead | `HERDR_SINGLE_CLAUDE_LEAD_MODEL` (Opus) | `HERDR_SINGLE_CODEX_LEAD_MODEL` (Sol) |
  | Helper | `HERDR_SINGLE_CLAUDE_HELPER_MODEL` (Haiku) | `HERDR_SINGLE_CODEX_HELPER_MODEL` (Luna) |
  | Reviewer | `HERDR_SINGLE_CLAUDE_REVIEWER_MODEL` (Sonnet) | `HERDR_SINGLE_CODEX_REVIEWER_MODEL` (Sol) |

  A successor lead keeps the starting lead's own model and effort. Helpers and reviewers run at `HERDR_SINGLE_HELPER_EFFORT` (`xhigh`).
- Only the 5-hour window counts. `quota.py suggest --provider <p>` turns it into a number of helpers: projected surplus at reset is spent on helpers, a window on pace gets few, and below `HERDR_SINGLE_LEAD_RESERVE_PCT` (30%) none. `HERDR_SINGLE_MAX_HELPERS` (6) is the ceiling.
- When the window runs out the panel parks the run; at the reset it resumes the same lead pane, or starts a fresh lead of the same provider if that pane is gone. `HERDR_SINGLE_LEAD_RESUME=fresh` always starts a fresh lead; `off` only warns.
- State lives under `~/.local/state/herdr-single`, apart from herdr-duo's, so both skills can be installed together.
- Optional: `~/.agents/skills/herdr-single/scripts/install-hooks.sh --claude-only` (or `--codex-only`) adds the quota guardian hook for that CLI.

Run `~/.agents/skills/herdr-single/scripts/preflight.sh` to check these. It is read-only.

### Known limitations (herdr-single)

Open on purpose; fix them when they start to cost time.

1. **Claude folder-trust dialog per helper worktree.** Claude Code asks once per worktree path (`~/.local/state/herdr-single/wt/<repo>-<hash>/<name>`). A Claude-only run therefore stops at the first spawn of each new helper name until the user answers the dialog in that pane; the skill never answers it. Codex is not affected: it trusts at the repository root. Reusing names (`h1`, `h2`, ...) makes it a one-time cost per name and repository.
   *Proposed fix:* a `trust-warmup.sh --repo <repo> [--names h1,h2,h3]` that pre-creates those worktree paths and prints them, so the user approves them once before a run; or pre-trusting them through Claude Code's settings if it gains a supported option for that.
2. **Usage-limited native goal after a fresh lead.** When a fresh lead of the same provider takes over after a reset, a native goal the provider marked `usage_limited` is not restored with `/goal`, because `transferable()` in the shared `goal-handoff.py` restores it only on the *other* provider (herdr-duo's case). The resume prompt and the portable checkpoint (`state.json`, `progress.json`, `goal.json`) still carry the task, and a lead resumed in place keeps its own goal.
   *Proposed fix:* allow a same-provider restore when the window has reset since the goal was limited; change it in herdr-duo, adjust `test_provider_quota_handoff_preserves_goal_without_renewing_budget`, then run `scripts/sync-shared.sh`.
3. **Duplicated test fixtures.** `tests/test_single.py` (herdr-single) and `tests/test_leads.py` / `tests/test_quota.py` (herdr-duo) carry near-identical `RunFixture` and `QuotaFixture` classes.
   *Proposed fix:* move them to a fixtures module listed in `scripts/shared-files.sh`.

### Shared scripts

herdr-single reuses most of herdr-duo's scripts (worktrees, dispatch, guard, delta, integration, cleanup, placement, goal transfer). Each skill folder stays self-contained, so the shared files are copies, listed in `scripts/shared-files.sh`. Change a shared file in `skills/herdr-duo`, then run `scripts/sync-shared.sh`; `scripts/check-shared.sh` (part of `validate.sh` and CI) fails when the copies drift.

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
