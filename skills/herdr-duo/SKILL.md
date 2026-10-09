---
name: herdr-duo
description: "Orchestrate development inside Herdr with adaptive delegation to Codex Luna and Claude Code Haiku, scaled to the task's real parallelism, with narrow escalation to Sol or Sonnet, isolated worktrees, cross-review, and verified integration. Use when the user invokes herdr-duo or asks for this Luna/Haiku team in Herdr."
---

# Herdr Duo

You are the lead, working in whatever repository the user is in. Stay on the model and provider the user chose for this session. Spend your turns on decisions: planning, routing, review judgment, integration and the final report. The scripts in `scripts/` do every deterministic step. Each script prints what it did, so you rarely need an extra turn to inspect.

Shell variables do not survive between tool calls. Use the literal absolute paths that `run-init.sh` prints. In this file, `$SKILL_DIR`, `$RUN` and `$REPO` stand for those printed values.

## Start

Start the lead in a Herdr pane. For Codex versions that advertise `--no-daemon` in `codex --help`, launch the lead with `codex --no-daemon`. A shared app-server daemon started outside Herdr may execute commands without the pane's `HERDR_*` environment even when the CLI itself inherited it. `spawn.sh` applies this flag to Codex workers and reviewers when supported.

If preflight reports a missing `HERDR_ENV`, report that the command environment lacks Herdr context and explain how to relaunch the lead. Do not infer that the user's terminal is outside Herdr solely from this failure. Never synthesize `HERDR_ENV=1`, copy another pane's IDs, or use the focused pane as a fallback. If a locally launched Codex still loses the variables, compare `printenv HERDR_ENV HERDR_PANE_ID HERDR_SOCKET_PATH` in the pane shell and in the agent's shell tool, then inspect Codex's shell environment policy.

1. Set `$SKILL_DIR` to this skill's base directory (the directory containing this `SKILL.md`), then run `$SKILL_DIR/scripts/preflight.sh`. It is read-only. If it fails, report the failing line and stop. A warning about one provider means you route its work to the other.
2. `$SKILL_DIR/scripts/run-init.sh --repo <repo> --goal "<one line>" [--commit] [--push]`. Pass `--commit` or `--push` only if the user's **initial** request explicitly asked for that. The script prints `RUN`, `REPO`, the branch and default branch, uncommitted counts, the repository's instruction files, dependency directories, and stale worktrees.
3. Read the repository's instruction files that it lists (AGENTS.md, CLAUDE.md, CONTRIBUTING.md, README, manifests). They define the checks and conventions for this repo. Read the base `herdr` skill only if a Herdr command fails or you need one that these scripts do not cover.

## Authorization

- Invocation authorizes: worker and reviewer panes, worktrees under the herdr-duo state directory, and integrating reviewed changes into the user's checkout as uncommitted edits.
- Commit and push happen only when recorded at `run-init`, that is, when the initial request asked for them. Never merge, rebase, reset, force-push, amend, use `--no-verify`, open a PR, deploy, or change authentication, billing or permissions unless explicitly asked for that exact action.
- Workers run with broad access by the user's choice (see the access profiles below). Their git restrictions are therefore enforced by instruction plus detection: run `guard.sh snapshot` before dispatch, and `guard.sh verify` after every settle and before integrating or committing. A violation stops the run until you have shown it to the user.

## Team and access profiles

| Session | Tier | Agent | Default profile |
|---|---|---|---|
| Luna (implementer) | base | Codex, `gpt-6-luna`, effort medium | `-s danger-full-access -a never` (full access, never asks) |
| Haiku (implementer) | base | Claude Code, `claude-haiku-5-5` | `--permission-mode auto`, plus `--add-dir` for its state directory |
| Sol (implementer) | strong | Codex, `gpt-6.1-sol`, effort high | same as Luna |
| Sonnet (implementer) | strong | Claude Code, `claude-sonnet-5-5` | same as Haiku |
| Codex reviewer | base or strong | Codex | `-s read-only -a never` |
| Claude reviewer | base or strong | Claude Code | `--permission-mode dontAsk`, edit tools disallowed |

`spawn.sh` applies these profiles (`--tier strong` selects Sol or Sonnet). The user can change them once, for every repository, in `~/.config/herdr-duo/config.env` (`HERDR_DUO_LUNA_MODEL`, `HERDR_DUO_LUNA_EFFORT`, `HERDR_DUO_LUNA_ACCESS=full|workspace`, `HERDR_DUO_HAIKU_MODEL`, `HERDR_DUO_HAIKU_MODE=auto|acceptEdits|default`, `HERDR_DUO_SOL_MODEL`, `HERDR_DUO_SOL_EFFORT`, `HERDR_DUO_SONNET_MODEL`, `HERDR_DUO_DEPS_NAMES`).

### Sizing the team (your judgment, no fixed cap)

- **Base workers scale with the plan's real parallelism.** Spawn one Luna or Haiku per independent task that has its own files, a clear acceptance check, and enough substance to pay for a fresh session (a new session costs about 16k tokens before any work). Use zero workers for work you can verify directly, and one for strictly sequential work. Three tiny edits are one task, not three workers.
- Do not spawn workers whose tasks would wait on each other or share a file; sequence those through one worker instead. When tasks outnumber good parallel slots, run waves: integrate a worker's delta, then give it the next task with a new assignment (its baseline has advanced).
- Mix providers so cross-review stays possible. With more than two workers, spawn the extra panes with `--split-from` on alternating existing panes, so none gets too narrow.
- **Strong sessions never scale horizontally.** At most one Sol or Sonnet session is live per run; `spawn.sh` and `escalate.sh` refuse a second. Plan a task as strong from the start only when it needs cross-cutting reasoning that cheap models get wrong, for example a financial rule spread over several files. Otherwise strong sessions come only from escalation (below).
- **Reviewers** are read-only and on demand, as set out in `references/review.md`. Close them once their report is in.
- Reuse live base sessions for follow-ups (`dispatch.sh --message`) and fix rounds (`dispatch.sh --fix`). Close sessions you will not reuse.
- Route localized, mechanical, test and doc work to Haiku. Route multi-file logic with invariants, and debugging with an unclear root cause, to Luna. A change is reviewed by the provider that did not write it. If a provider is unavailable or rate-limited, send its work to the other.
- Do not implement routine work yourself. If the workers and the escalation fail, finish the deterministic checks and report the blocker.

### Escalation to Sol or Sonnet

Escalate a base worker's task only when one of these holds:

1. **Two failed rounds on the same problem**: the initial round plus one `dispatch.sh --fix` round, each failed by its own report, by your checks, or by a blocking review finding. A failure caused by your assignment (missing context, wrong ownership, unclear criteria) does not count: fix the assignment and resend.
2. **Cross-cutting reasoning** turned out to be required mid-task (`--cross-cutting`, with the evidence in `--reason`).

Never escalate mechanical work, test adjustments or documentation; base workers handle those well. For those, after two failed rounds, stop and report.

```bash
$SKILL_DIR/scripts/escalate.sh --run $RUN --name <worker> --reason "<what failed twice, in one line>"
```

It saves the failed attempt as a patch, closes the base session, and starts a new, dedicated strong session in the same worktree (by default from the other provider, a different model family). Write its assignment from the escalation template in `references/assignments.md`: only the failing problem, narrowly scoped. Dispatch it, review it like any change (the reviewer is the other provider), integrate it, and close it with `cleanup.sh` right away, so it does not stay live and use up quota. A strong session gets at most one fix round. If it still fails, stop and report the blocker; there is no further escalation.

## Workflow

1. **Plan.** Write acceptance criteria, dependencies and file ownership per task. Each file has one writer. Shared contracts, lockfiles, schemas and generated files get exactly one writer.
2. **Spawn** each implementer: `$SKILL_DIR/scripts/spawn.sh --run $RUN --name luna --provider codex --role implementer --deps-auto`. Then the others, with `--split-from <an existing worker pane> --direction down|right` so the panes do not get too narrow. Give each worker a short task-based name (`luna-api`, `haiku-docs`). Workers start from your current checkout, including uncommitted work; secret-looking files are skipped. Use `--from-head` to start from HEAD only. If spawn reports **STARTUP DIALOG**, see `references/recovery.md`.
3. **Guard:** `$SKILL_DIR/scripts/guard.sh snapshot --run $RUN`.
4. **Assign.** Write `$RUN/<name>/assignment.md` from `references/assignments.md`.
5. **Dispatch** with one background command: `$SKILL_DIR/scripts/dispatch-all.sh --run $RUN`. It runs every worker in parallel and prints reports in order; pass worker names to dispatch only a subset. On hosts without background notifications, run it in the foreground. If unavailable, run `dispatch.sh --run $RUN --name <name>` for each worker in parallel.
6. **Settle.** Run `guard.sh verify`. Then compute ground truth with `delta.sh --state <state_dir> --out <state_dir>/delta.patch`, where `<state_dir>` is the one `spawn.sh` printed (`$RUN/<name>`, or the original worker's directory for an escalated session). Judge the delta, never the report alone. A rejected delta goes back as `dispatch.sh --fix`; two failed rounds trigger the escalation rule above.
7. **Review** per `references/review.md`, sized to the risk of the change.
8. **Integrate, validate and finish** per `references/integration.md`.

## Invariants (and why)

- **Never answer a dialog.** Never type into a pane that shows a trust or approval dialog. The Enter of a prompt would answer it on the user's behalf. Both scripts check the screen first, because Herdr can report such a pane as idle.
- **Never overwrite later edits.** Never overwrite a file that changed after its baseline; those are the user's edits. `integrate.sh` refuses such conflicts.
- **"Done" is not proof.** A verified delta, a clean guard check, and checks you ran yourself are the proof.
- **Ports, databases and full suites run once.** Workers run fast, targeted checks. Anything that binds fixed ports, uses shared databases or services, or runs full or end-to-end suites runs once, by you, after integration, because concurrent runs collide.
- **No team state in the repository.** Team state lives under `$RUN`, never in tracked files.

- **One strong session at a time, closed when done.** Sol and Sonnet are expensive; they work one narrow problem and close.

`$SKILL_DIR/scripts/status.sh --run $RUN` prints every session with its tier, status and fix rounds, the live strong session, the escalations, and what still needs a decision. Use it instead of reading `state.json`.

References: `assignments.md` (assignment, escalation and reviewer templates), `review.md` (risk tiers, cross-review, the third reviewer), `integration.md` (integrate, validate, commit, push, cleanup, report), `recovery.md` (dialogs, blocked or stalled sessions, guard violations, quota, compaction).
