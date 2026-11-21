---
name: herdr-single
description: "Run one task on a single subscription inside Herdr, Claude only or Codex only: the lead you started (for example Opus or Sol) does the main work and opens helpers and reviewers of the same subscription, with a live progress and 5h quota panel, isolated worktrees, independent review, verified integration, and a lead that parks when its window runs out and resumes at the reset. Use when the user invokes herdr-single, or wants herdr-duo-style orchestration in Herdr with only one of Claude or Codex available."
---

# Herdr Single

herdr-single is herdr-duo for one subscription. The user does not always keep both Claude and Codex active, so a run uses **only the subscription of the lead that started it**:

- **Lead:** the session the user started, for example Opus 5.5 (Claude) or Sol 6.1 (Codex). It does the main work **itself**. It plans, holds the user's checkout, integrates and delivers.
- **Helpers and reviewers:** sessions of the **same** subscription, Haiku or Luna by default for helpers, Sonnet or a fresh Sol for reviewers, or any model of that provider you name. Open as many as the window can carry.

Nothing ever starts on the other subscription. It may be logged out, uninstalled or out of quota. To combine both, use herdr-duo instead.

Only the 5-hour window counts. Never plan, warn or throttle on weekly quota.

The scripts in `scripts/` do every deterministic step and print what they did. Shell variables do not survive between tool calls: use the literal absolute paths `run-init.sh` prints. Here `$SKILL_DIR`, `$RUN` and `$REPO` stand for those values.

## Start

Start in a Herdr pane. With Codex, launch it as `codex --no-daemon` when `codex --help` lists that flag: a shared daemon started outside Herdr can lose the pane's `HERDR_*` variables. If preflight reports a missing `HERDR_ENV`, explain how to relaunch inside Herdr; never set `HERDR_ENV=1` yourself or borrow another pane's IDs.

1. Run `$SKILL_DIR/scripts/preflight.sh` (read-only). It detects the subscription from your pane and checks only that CLI. Report a failing line and stop. If it shows `quota hook (<provider>): no`, tell the user once that `$SKILL_DIR/scripts/install-hooks.sh --<provider>-only` adds the quota line to every lead turn.
2. Run `$SKILL_DIR/scripts/run-init.sh --repo <repo> --goal "<one line>" [--provider codex|claude] [--lead-model <actual model>] [--lead-effort <actual effort>] [--commit] [--push]`. Pass `--provider` only when your pane's agent cannot be detected. Pass `--commit` or `--push` only if the user's **initial** request asked for that. It prints `RUN`, the repository facts, the run's provider and models, and the 5h window. It records your pane as the lead and opens the **status panel** beside you (`--no-panel` only if the user asked).
3. Read the repository's instruction files it lists (AGENTS.md, CLAUDE.md, CONTRIBUTING.md, README, manifests). They define checks and conventions. Read the base `herdr` skill only if a Herdr command fails or you need one these scripts do not cover.

## Authorization

- Invocation authorizes helper and reviewer panes on the run's subscription, worktrees under the herdr-single state directory, and integrating reviewed changes into the user's checkout as uncommitted edits.
- Commit and push happen only when recorded at `run-init`. Never merge, rebase, reset, force-push, amend, use `--no-verify`, open a PR, deploy, or change authentication, billing or permissions unless asked for that exact action.
- Sessions run with broad access (see `spawn.sh`). Their git restrictions are enforced by instruction plus detection: run `guard.sh snapshot` before dispatch and `guard.sh verify` after every settle and before integrating or committing. A violation stops the run until you have shown it to the user.

## Splitting the work

**1. Do the main work yourself.** You are the strongest session on this task. Delegate when it saves time, or when it spends quota that would otherwise be lost at the window's reset.

**2. Pace helpers by the one window.** There is no other pool to send work to, so the question is how much parallel work this window can carry now. `quota.py suggest --provider <p> --live <open sessions>` answers with a number and a reason; the hook and the panel show the same line as `new helpers now: N`.
- **Projected surplus** (quota that would still be unused at reset at the current pace) is spent on helpers.
- A window **on pace** to be used up gets few or no new helpers.
- Below the lead's reserve (`HERDR_SINGLE_LEAD_RESERVE_PCT`, default 30%) the window is kept for your own work: no new helpers.
- `HERDR_SINGLE_MAX_HELPERS` (default 6) caps live sessions.

Do not manufacture work to burn quota. A helper costs a fresh session, so a few tiny edits are one helper, not several.

**3. Good uses for helpers:**
- searching and reading code or logs;
- running and fixing targeted tests;
- mechanical or repetitive edits;
- documentation;
- parallel independent pieces with their own files.

Choose any model of the run's provider with `spawn.sh --model`, for example a stronger model for one hard sub-problem.

Folder trust: Codex trusts at the repository root, so once the user trusts a repository every Codex session there starts without a dialog. Claude Code asks once per worktree path, and paths are stable per repository and session name. Reuse a small set of helper names (`h1`, `h2`, ...) so the user answers that dialog once per name, not once per task. When a helper stops at a dialog, never answer it: tell the user the pane.

**Effort.** Helpers and reviewers run at `HERDR_SINGLE_HELPER_EFFORT` (default `xhigh`). A successor lead inherits the effort you were started with: `run-init.sh` reads it from the exact session (pass `--lead-effort` when it cannot). `spawn.sh --effort` overrides it for one session.

**4. No escalation ladder.** If a helper fails the same problem twice, take it yourself or give it to a stronger model of the same provider. Do not loop.

**5. Skills.** An assignment may tell a session to use any skill installed for the run's provider (`~/.claude/skills` for Claude, `~/.agents/skills` for Codex). Name the skill and what it is for.

**6. One writer per file.** Assign file ownership when you split the work. Shared contracts, lockfiles, schemas and generated files get exactly one writer.

## Quota guardian

The window's source needs no live pane: Claude's is the Herdr usage bar, Codex's its newest session rollout. A window whose reset has passed reads as unused. `quota.py` reports what is left, the reset time, the burn rate and the projected surplus.

- With the hook installed, every prompt you receive starts with that line. During a long turn, the hook speaks again on a tool call when a warning or alert is new. Without the hook, run `$SKILL_DIR/scripts/quota.py line --provider <p>`.
- **QUOTA LOW** (`HERDR_SINGLE_LEAD_WARN_PCT`, default 10%): no other subscription can take over. Checkpoint with `progress.sh note`, stop opening helpers, and bring your work and your helpers' to a safe point: settle or collect what is running, and record exactly what comes next.

## Panel, parking and resume

The panel is a script, not an agent, and uses no quota. It shows:
- your checklist and what you are doing now;
- the 5h window and `new helpers now`;
- the lead's state, and every session;
- the last checks, git and CI.

New panes are placed automatically into the run's balanced layout: the largest owned pane is split along its longer side, the lead's pane is never split, the caller's tab is tried first, and a new tab opens when nothing fits.

The panel watches the lead:
- **Window out** (`HERDR_SINGLE_LEAD_HANDOFF_PCT`, default 2%, or a limit message on its screen, for an idle lead): the run is **parked** until the window's reset. The state stays intact; helpers already running finish their turn.
- **At the reset** it resumes the run (`HERDR_SINGLE_LEAD_RESUME`):
  - `auto` (default): if the lead's pane is still alive, it gets a short resume prompt and continues **with its own context**; otherwise a fresh lead of the same provider and model starts below it;
  - `fresh`: always a fresh lead;
  - `off`: the panel only warns and alerts; the user resumes the run.
- **Context full, quota left:** you may pass the run to a fresh lead of the same provider yourself, at a safe point: `handoff.sh --run $RUN --reason "context full"`. Write a `note` first.
- **Lead fence:** a lead pane is never typed into except to deliver a resume prompt. After a handoff to a fresh lead, the old pane is fenced: every script refuses it. Stop when told you are no longer the lead.

Keep the panel and any successor informed. Each call is one short command:

```bash
$SKILL_DIR/scripts/progress.sh --run $RUN plan "<step 1>" "<step 2>" ...   # after planning; again if the plan changes
$SKILL_DIR/scripts/progress.sh --run $RUN step <n> active|done|failed
$SKILL_DIR/scripts/progress.sh --run $RUN check "<label>" <exit code> "<summary, e.g. 256/268 passed>"
$SKILL_DIR/scripts/progress.sh --run $RUN note "<decision or next step a successor must know>"
```

Write a `note` at each milestone: a plan decision, an integration, a dispatch you are about to wait on. A genuinely required unanswered decision is recorded as `waiting for user: <question>` with the reason it blocks work. Optional questions and already authorized actions must not become blockers. Write steps in the user's language.

### Resume a run

When you were started or prompted to resume a run (a resume prompt after the reset, a fresh-lead prompt, or the user asks after compaction or a stop):

1. Run `preflight.sh`, then `status.sh --run $RUN`. A resumed or fresh lead is already the lead (`you are the lead`). Only if it says `NOT the lead` and the user asked you to take over, run `handoff.sh --run $RUN --adopt` (the pane must run the run's provider).
2. Read `$RUN/handoff.md`, `progress.json`, `state.json` and `$RUN/goal.json` if present. You inherit the original task, the user's constraints and the recorded authorization, including commit and push. A resume is a continuation, not a new approval request. Do not re-plan finished steps or spawn duplicates of live sessions.
3. Run `guard.sh verify --run $RUN`.
4. Inspect every live session and its assignment or report. Reattach dispatched work with `dispatch.sh --run $RUN --name <name> --collect` in the background: it sends nothing, waits, and prints the report. Never restart a suite, resend an assignment or spawn a replacement before checking the existing process.
5. Reconcile `waiting for user` notes against existing authorization, write a takeover note, and continue the next unfinished action through validation, integration and authorized delivery and cleanup. Do not stop after a status update or a background dispatch.
6. Restore goal continuity as described below. Goal-tool availability must never block the work.

### Goal continuity

The portable goal is `state.json.goal` plus `progress.json` and `$RUN/goal.json`. A lead resumed in place keeps its own session and native goal. When a **fresh** lead starts, `handoff.sh` captures the old lead's native goal read-only into `$RUN/goal-native.json`, restores an active goal with `/goal` in the successor, and records the outcome in `$RUN/goal-transfer.json`. A goal the provider marked usage-limited is not restored natively on the same provider; the resume prompt and the portable checkpoint carry it. Provider formats are private, so this is best effort.

When the user explicitly asks for a goal, record it and keep it current at milestones:
```bash
$SKILL_DIR/scripts/progress.sh --run $RUN goal '<JSON object with objective, acceptance criteria, remaining work, status>'
```
Never reactivate paused, blocked, completed or budget-exhausted goals. Carry over a known remaining token budget; never reset it to the original total. Mark a goal complete only when the whole delivery, including required CI and cleanup, meets its criteria.

## Workflow for delegated work

1. **Plan.** Write acceptance criteria and file ownership per helper task, and record the steps with `progress.sh plan`.
2. **Spawn:** `$SKILL_DIR/scripts/spawn.sh --run $RUN --name <task> [--model M] --deps-auto`. The provider is the run's; `--provider` may only repeat it. Use short task-based names. Sessions start from the user's checkout, including uncommitted work (secret-looking files are skipped); `--from-head` starts from HEAD only, and `--base-from <name>` starts from that session's worktree. If spawn reports **STARTUP DIALOG**, see `references/recovery.md`.
3. **Guard:** `$SKILL_DIR/scripts/guard.sh snapshot --run $RUN`.
4. **Assign:** write `$RUN/<name>/assignment.md` from `references/assignments.md`.
5. **Dispatch** in the background: `$SKILL_DIR/scripts/dispatch-all.sh --run $RUN` dispatches every live helper in parallel and prints their reports in order. Pass names for a subset, or use `dispatch.sh --name <name>` for one.
6. **Settle.** Run `guard.sh verify`, then `delta.sh --state <state_dir> --out <state_dir>/delta.patch`. Judge the delta, never the report alone. A rejected delta goes back as `dispatch.sh --fix`.
7. **Review** per `references/review.md`, sized to risk. Without a second subscription, independence comes from a fresh reviewer session that never saw the author's context.
8. **Integrate, validate and finish** per `references/integration.md`.

## Invariants (and why)

- **One subscription.** `spawn.sh` and `handoff.sh` refuse any session of the other provider, so a run never depends on a subscription the user may not have.
- **Never answer a dialog.** Never type into a pane that shows a trust or approval dialog: the Enter of a prompt would answer it on the user's behalf. The scripts check the screen first, because Herdr can report such a pane as idle.
- **Never overwrite later edits.** `integrate.sh` refuses a file that changed after its baseline; those changes belong to the user or to another integration.
- **"Done" is not proof.** A verified delta, a clean guard check, and checks you ran yourself are the proof.
- **Ports, databases and full suites run once,** by the lead, after integration, because concurrent runs collide. Sessions run fast, targeted checks.
- **No team state in the repository, and none left behind.** It lives under `$RUN`, and `cleanup.sh --run $RUN --finish` deletes `$RUN` once every session is cleaned. `cleanup.sh --prune` removes leftovers of abandoned runs; it never deletes a worktree.
- **One lead.** Only the lead touches the user's checkout, commits and pushes.
- **Only the 5h window.** Weekly quota never enters a decision.

`$SKILL_DIR/scripts/status.sh --run $RUN` prints the window, `new helpers now`, the lead, every session, alerts, and what still needs a decision. Use it instead of reading `state.json`.

References:
- `assignments.md`: helper and reviewer templates;
- `review.md`: risk tiers and same-subscription independent review;
- `integration.md`: integrate, validate, commit, push, cleanup, report;
- `recovery.md`: dialogs, stalled sessions, guard violations, parking and resume, compaction.
