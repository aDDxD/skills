---
name: herdr-duo
description: "Orchestrate development inside Herdr with adaptive delegation to Codex Luna and Claude Code Haiku, isolated worktrees, cross-review, and verified integration. Use when the user invokes herdr-duo or asks for this Luna/Haiku team in Herdr."
---

# Herdr Duo

You are the lead, working in whatever repository the user is in. Stay on the model and provider the user chose for this session. Spend your turns on decisions: planning, routing, review judgment, integration and the final report. The scripts in `scripts/` do every deterministic step. Each script prints what it did, so you rarely need an extra turn to inspect.

Shell variables do not survive between tool calls. Use the literal absolute paths that `run-init.sh` prints. In this file, `$SKILL_DIR`, `$RUN` and `$REPO` stand for those printed values.

## Start

1. `~/.agents/skills/herdr-duo/scripts/preflight.sh`. It is read-only. If it fails, report the failing line and stop. A warning about one provider means you route its work to the other.
2. `$SKILL_DIR/scripts/run-init.sh --repo <repo> --goal "<one line>" [--commit] [--push]`. Pass `--commit` or `--push` only if the user's **initial** request explicitly asked for that. The script prints `RUN`, `REPO`, the branch and default branch, uncommitted counts, the repository's instruction files, dependency directories, and stale worktrees.
3. Read the repository's instruction files that it lists (AGENTS.md, CLAUDE.md, CONTRIBUTING.md, README, manifests). They define the checks and conventions for this repo. Read the base `herdr` skill only if a Herdr command fails or you need one that these scripts do not cover.

## Authorization

- Invocation authorizes: worker and reviewer panes, worktrees under the herdr-duo state directory, and integrating reviewed changes into the user's checkout as uncommitted edits.
- Commit and push happen only when recorded at `run-init`, that is, when the initial request asked for them. Never merge, rebase, reset, force-push, amend, use `--no-verify`, open a PR, deploy, or change authentication, billing or permissions unless explicitly asked for that exact action.
- Workers run with broad access by the user's choice (see the access profiles below). Their git restrictions are therefore enforced by instruction plus detection: run `guard.sh snapshot` before dispatch, and `guard.sh verify` after every settle and before integrating or committing. A violation stops the run until you have shown it to the user.

## Team and access profiles

| Session | Agent | Default profile |
|---|---|---|
| Luna (implementer) | Codex, `gpt-6-luna`, effort medium | `-s danger-full-access -a never` (full access, never asks) |
| Haiku (implementer) | Claude Code, `claude-haiku-5-5` | `--permission-mode auto`, plus `--add-dir` for its state directory |
| Codex reviewer | Codex | `-s read-only -a never` |
| Claude reviewer | Claude Code | `--permission-mode dontAsk`, edit tools disallowed |

`spawn.sh` applies these profiles. The user can change them once, for every repository, in `~/.config/herdr-duo/config.env` (`HERDR_DUO_LUNA_MODEL`, `HERDR_DUO_LUNA_EFFORT`, `HERDR_DUO_LUNA_ACCESS=full|workspace`, `HERDR_DUO_HAIKU_MODEL`, `HERDR_DUO_HAIKU_MODE=auto|acceptEdits|default`, `HERDR_DUO_DEPS_NAMES`).

- **Default: two implementers**, one of each provider. Use zero for work you can verify directly, and one for sequential work. Add a third or fourth implementer only if the user's initial request asked for it.
- **Reviewers** are read-only and on demand, as set out in `references/review.md`. At most one extra reviewer runs alongside two implementers. Cap: four live sessions besides you.
- A fresh session costs real context; a new Codex session measured about 16k tokens before any work. Reuse live sessions for follow-ups and fix rounds (`dispatch.sh --message`). Close sessions you will not reuse.
- Route localized, mechanical, test and doc work to Haiku. Route multi-file logic with invariants, and debugging with an unclear root cause, to Luna. A change is reviewed by the provider that did not write it. If a provider is unavailable or rate-limited, send its work to the other.
- Do not implement routine work yourself. If both workers fail, finish the deterministic checks and report the blocker.

## Workflow

1. **Plan.** Write acceptance criteria, dependencies and file ownership per task. Each file has one writer. Shared contracts, lockfiles, schemas and generated files get exactly one writer.
2. **Spawn** each implementer: `$SKILL_DIR/scripts/spawn.sh --run $RUN --name luna --provider codex --role implementer --deps-auto`. Then the second one, with `--split-from <first pane> --direction down` so the panes do not get too narrow. Workers start from your current checkout, including uncommitted work; secret-looking files are skipped. Use `--from-head` to start from HEAD only. If spawn reports **STARTUP DIALOG**, see `references/recovery.md`.
3. **Guard:** `$SKILL_DIR/scripts/guard.sh snapshot --run $RUN`.
4. **Assign.** Write `$RUN/<name>/assignment.md` from `references/assignments.md`.
5. **Dispatch** both before waiting on either. Run `$SKILL_DIR/scripts/dispatch.sh --run $RUN --name <name>` as a background command for each worker. The completion notification carries the final report, so do not poll. On hosts without background notifications, run `dispatch.sh ... & dispatch.sh ... & wait` in one command.
6. **Settle.** Run `guard.sh verify`. Then compute ground truth with `delta.sh --state $RUN/<name> --out $RUN/<name>/delta.patch`. Judge the delta, never the report alone.
7. **Review** per `references/review.md`, sized to the risk of the change.
8. **Integrate, validate and finish** per `references/integration.md`.

## Invariants (and why)

- **Never answer a dialog.** Never type into a pane that shows a trust or approval dialog. The Enter of a prompt would answer it on the user's behalf. Both scripts check the screen first, because Herdr can report such a pane as idle.
- **Never overwrite later edits.** Never overwrite a file that changed after its baseline; those are the user's edits. `integrate.sh` refuses such conflicts.
- **"Done" is not proof.** A verified delta, a clean guard check, and checks you ran yourself are the proof.
- **Ports, databases and full suites run once.** Workers run fast, targeted checks. Anything that binds fixed ports, uses shared databases or services, or runs full or end-to-end suites runs once, by you, after integration, because concurrent runs collide.
- **No team state in the repository.** Team state lives under `$RUN`, never in tracked files.

References: `assignments.md` (assignment and reviewer templates), `review.md` (risk tiers, cross-review, the third reviewer), `integration.md` (integrate, validate, commit, push, cleanup, report), `recovery.md` (dialogs, blocked or stalled sessions, guard violations, quota, compaction).
