---
name: herdr-duo
description: "Run one task across both subscriptions inside Herdr: the lead you started (Opus or Sol) does the main work, delegates a separable slice to its sibling lead on the other subscription (Sol or Opus) so both 5-hour windows are used evenly, and both leads freely open Luna/Haiku helpers from either subscription. Keeps a live progress and quota panel, automatic lead handoff, isolated worktrees and verified integration. Use when the user invokes herdr-duo or asks to split work between Claude and Codex in Herdr."
---

# Herdr Duo

herdr-duo makes the user's two subscriptions, Claude and Codex, work as one. Each 5-hour window is a separate pool, and quota left unused at its reset is lost. The skill exists so that both pools are spent on useful work, evenly, without the lead's own pool running dry mid-task.

- **Principal lead:** the session the user started, normally Opus 5.5 or Sol 6.1. It does the main work **itself**. It plans, holds the user's checkout, integrates and delivers.
- **Sibling lead:** the other subscription's lead of the fixed pair (Opus ↔ Sol), opened for a separable slice. It works in its own worktree and reports to the principal. Astra is never used.
- **Helpers:** Luna and Haiku by default, or any model you name. Either lead opens as many as the task can use, **from either subscription**.

Only the 5-hour windows count. Never plan, warn or throttle on weekly quota.

The scripts in `scripts/` do every deterministic step and print what they did. Shell variables do not survive between tool calls: use the literal absolute paths `run-init.sh` prints. Here `$SKILL_DIR`, `$RUN` and `$REPO` stand for those values.

## Start (principal)

Start in a Herdr pane. With Codex, launch it as `codex --no-daemon` when `codex --help` lists that flag: a shared daemon started outside Herdr can lose the pane's `HERDR_*` variables. If preflight reports a missing `HERDR_ENV`, explain how to relaunch inside Herdr; never set `HERDR_ENV=1` yourself or borrow another pane's IDs.

1. Run `$SKILL_DIR/scripts/preflight.sh` (read-only). Report a failing line and stop. A provider warning means you run the task on the other subscription only. If it shows `quota hook (claude): no`, tell the user once that `$SKILL_DIR/scripts/install-hooks.sh` adds the quota line to every lead turn.
2. Run `$SKILL_DIR/scripts/run-init.sh --repo <repo> --goal "<one line>" [--lead-model <actual model>] [--lead-effort <actual effort>] [--commit] [--push]`. Pass `--commit` or `--push` only if the user's **initial** request asked for that. It prints `RUN`, the repository facts, the lead pair, both 5h windows, and the instruction files. It records your pane as the principal and opens the **status panel** beside you (`--no-panel` only if the user asked).
3. Read the repository's instruction files it lists (AGENTS.md, CLAUDE.md, CONTRIBUTING.md, README, manifests). They define checks and conventions. Read the base `herdr` skill only if a Herdr command fails or you need one these scripts do not cover.

Do not ask the user which worker level to use; that choice no longer exists.

## Authorization

- Invocation authorizes the sibling and helper panes, worktrees under the herdr-duo state directory, and integrating reviewed changes into the user's checkout as uncommitted edits.
- Commit and push happen only when recorded at `run-init`. Never merge, rebase, reset, force-push, amend, use `--no-verify`, open a PR, deploy, or change authentication, billing or permissions unless asked for that exact action.
- Sessions run with broad access (see `spawn.sh`). Their git restrictions are enforced by instruction plus detection: run `guard.sh snapshot` before dispatch and `guard.sh verify` after every settle and before integrating or committing. A violation stops the run until you have shown it to the user.

## Splitting the work

**1. Do the main work yourself.** You are the strongest session on this task. Delegate only when it saves time or uses quota that would otherwise go to waste.

**2. Open the sibling when the task has a separable slice:**
- its own files;
- a clear acceptance check;
- enough substance to repay a fresh lead's context, roughly an hour or more of work.

Size the slice by quota: the sibling's share of the work tracks its window's headroom (projected surplus) against yours. Rebalance at slice boundaries by giving the next slice to the lead whose window has more to spend. Never interrupt work in progress just to rebalance.

**3. No separable slice:** do the task alone. `run-init.sh` records which subscription led, and `quota.py suggest` recommends starting the **next** task on the other one when headroom is similar. Balance then happens across tasks.

**4. Helpers are free.** Open as many as the task can use, from either subscription. Good uses:
- searching and reading code or logs;
- running and fixing targeted tests;
- mechanical or repetitive edits;
- documentation;
- reviewing small diffs;
- parallel independent pieces.

Route each helper to `quota.py suggest --for helper --mine <your provider>`, which the hook and the panel also show. It favors the window that would otherwise go unused, and keeps a reserve (`HERDR_DUO_LEAD_RESERVE_PCT`, default 30%) in your own window for your own work. Choose any model with `spawn.sh --model`, for example a stronger model for one hard sub-problem. A helper costs a fresh session, so a few tiny edits are one helper, not several.

Folder trust: Codex trusts at the repository root, so once the user trusts a repository every Codex session there starts without a dialog. Claude Code asks once per worktree path, and paths are stable per repository and session name. Reuse a small set of Claude helper names (`haiku1`, `haiku2`, ...) so the user answers that dialog once per name, not once per task. When a helper stops at a dialog, never answer it: tell the user the pane, or route the work to a Codex helper.

**Effort parity.** The sibling, and any handoff successor, run at the effort the principal was started with: start at low and the sibling is low, start at medium and it is medium. `run-init.sh` reads it from the exact session (pass `--lead-effort` when it cannot) and `spawn.sh` applies it, translated per CLI (Codex `ultra` becomes Claude `max`). Helpers always run at `xhigh` (`HERDR_DUO_HELPER_EFFORT`). `spawn.sh --effort` overrides either for one session.

**5. No escalation ladder.** If a helper fails the same problem twice, take it yourself or give it to a stronger model. Do not loop.

**6. Skills from either side.** An assignment may tell a session to use any skill installed for its provider (`~/.claude/skills` for Claude, `~/.agents/skills` for Codex). Name the skill and what it is for.

**7. One writer per file, across both teams.** The principal assigns ownership when it splits the work. Shared contracts, lockfiles, schemas and generated files get exactly one writer.

## Quota guardian

Every lead guards both 5h windows. The sources need no live pane:
- **Claude:** the Herdr usage bar.
- **Codex:** its newest session rollout. A window whose reset has passed reads as unused.

For each window, `quota.py` reports what is left, the reset time, the burn rate, and the **projected surplus**: what would still be unused at reset at the current pace.

- With the hook installed, every prompt you receive starts with that line. During a long turn, the hook speaks again on a tool call when a warning or alert is new. Without the hook, run `$SKILL_DIR/scripts/quota.py line`.
- Give new work to the window with the larger surplus. Spend a window that resets soon with quota left. Do not manufacture work to equalize percentages.
- **QUOTA LOW** (`HERDR_DUO_LEAD_WARN_PCT`, default 10%):
  - **principal:** checkpoint with `progress.sh note`, then pass the role at a safe point with `handoff.sh --run $RUN --reason "quota low"` (not in the middle of an integration);
  - **sibling:** stop at a safe point and send your report block with `STATUS: partial`.

## The sibling lead

**Principal, to open the sibling:**
```bash
$SKILL_DIR/scripts/spawn.sh --run $RUN --name <opus|sol> --provider <the other subscription> --level sibling --deps-auto
```
Write `$RUN/<name>/assignment.md` from the sibling template in `references/assignments.md`. Then dispatch it in the background with a long timeout (`dispatch.sh --run $RUN --name <name> --timeout-min 240`) and keep working on your own part. Integrate its slice like any delta: `delta.sh`, review, `integrate.sh`.

**Sibling, when you are one:**
- You lead your slice inside your own worktree, under the same rules as the principal, except that:
  - you never touch the user's checkout;
  - you never commit;
  - you never open another sibling.
- Your helpers start from your worktree with `--base-from <your name>`. You integrate them into your worktree with `integrate.sh`, which refuses any other target.
- You dispatch and clean up only the sessions you opened.
- Finish with the report block from your assignment.

`status.sh` tells each pane what it is ("you are the principal" or "you are the sibling").

**Cross-review comes for free.** Each lead belongs to the other subscription, so each reviews the other's medium- and high-risk deltas: send the reviewer template with `dispatch.sh --message`. For your own changes as principal, write `git -C $REPO diff > $RUN/lead.patch` and send that path.

**If the sibling's window runs out,** the panel alerts the principal. Collect its slice with `delta.sh --state <its state_dir>`, integrate what is sound, take or reassign the rest, and reopen a sibling after its reset if a slice remains.

## Panel and lead handoff

The panel is a script, not an agent, and uses no quota. It shows:
- your checklist and what you are doing now;
- both 5h windows and where new helper work should go;
- both leads, and every helper grouped by the lead that owns it;
- the last checks, git and CI.

New panes are placed automatically into the run's balanced layout: the largest owned pane is split along its longer side, the principal's pane is never split, the caller's tab is tried first, and a new tab opens when nothing fits.

The panel watches both leads:
- **Principal:** an idle principal that has run out (`HERDR_DUO_LEAD_HANDOFF_PCT`, default 2%, or a limit message on its screen) is handed off automatically. Before handing off, the successor's quota is checked.
  - A **live sibling is promoted** to principal: no new session starts, and it already knows the task.
  - Otherwise a fresh lead of the pair model starts below the old pane.
  - A provider that ran out waits for its real reset. When both are out, the run is stranded and resumes when either window resets.
  - `HERDR_DUO_LEAD_FALLBACK=off` makes the panel only warn.
- **Sibling:** a sibling that runs out raises an alert for the principal.
- **Lead fence:** a lead pane is never typed into except to deliver a handoff prompt. After a handoff, the old principal is fenced: every script refuses it. Stop when told you are no longer a lead.

Keep the panel and any successor informed. Each call is one short command:

```bash
$SKILL_DIR/scripts/progress.sh --run $RUN plan "<step 1>" "<step 2>" ...   # after planning; again if the plan changes
$SKILL_DIR/scripts/progress.sh --run $RUN step <n> active|done|failed
$SKILL_DIR/scripts/progress.sh --run $RUN check "<label>" <exit code> "<summary, e.g. 256/268 passed>"
$SKILL_DIR/scripts/progress.sh --run $RUN note "<decision or next step a successor must know>"
```

Write a `note` at each milestone: a plan decision, a slice handed to the sibling, an integration, a dispatch you are about to wait on. A genuinely required unanswered decision is recorded as `waiting for user: <question>` with the reason it blocks work. Optional questions and already authorized actions must not become blockers. Write steps in the user's language.

### Resume a run

When you were started or promoted to resume a run (a handoff prompt, or the user asks after compaction or a stop):

1. Run `preflight.sh`, then `status.sh --run $RUN`. A successor or promoted sibling is already the principal (`you are the principal`). Only if it says `NOT a lead` and the user asked you to take over, run `handoff.sh --run $RUN --adopt`.
2. Read `$RUN/handoff.md`, `progress.json`, `state.json` and `$RUN/goal.json` if present. You inherit the original task, the user's constraints and the recorded authorization, including commit and push. A handoff is a continuation, not a new approval request. Do not re-plan finished steps or spawn duplicates of live sessions.
3. **If you were promoted from sibling,** bring your slice to a safe point first. Your former record now shows `promoted`, and your worktree still holds your slice: integrate it into the user's checkout like any delta (`delta.sh --state $RUN/<your former name>`, then `integrate.sh`). Every helper of the run is now yours.
4. Run `guard.sh verify --run $RUN`.
5. Inspect every live session and its assignment or report. Reattach dispatched work with `dispatch.sh --run $RUN --name <name> --collect` in the background: it sends nothing, waits, and prints the report. Never restart a suite, resend an assignment or spawn a replacement before checking the existing process.
6. Reconcile `waiting for user` notes against existing authorization, write a takeover note, and continue the next unfinished action through validation, integration and authorized delivery and cleanup. Do not stop after a status update or a background dispatch.
7. Restore goal continuity as described below. Goal-tool availability must never block the work.

### Goal continuity across providers

The portable goal is `state.json.goal` plus `progress.json` and `$RUN/goal.json`. When a **fresh** successor starts, `handoff.sh` captures the old lead's native goal read-only into `$RUN/goal-native.json`, restores an active goal with `/goal` in the successor, and records the outcome in `$RUN/goal-transfer.json`. Provider formats are private, so this is best effort: on failure, the ordinary resume prompt and the portable checkpoint carry the task. A promoted sibling keeps its own session; continue the portable goal there.

When the user explicitly asks for a goal, record it and keep it current at milestones:
```bash
$SKILL_DIR/scripts/progress.sh --run $RUN goal '<JSON object with objective, acceptance criteria, remaining work, status>'
```
Never reactivate paused, blocked, completed or budget-exhausted goals. Carry over a known remaining token budget; never reset it to the original total. Mark a goal complete only when the whole delivery, including required CI and cleanup, meets its criteria.

## Workflow for delegated work

1. **Plan.** Write acceptance criteria and file ownership per slice or helper task, and record the steps with `progress.sh plan`.
2. **Spawn:** `$SKILL_DIR/scripts/spawn.sh --run $RUN --name <task> --provider <suggested> [--model M] --deps-auto`. Use short task-based names. Sessions start from the user's checkout, including uncommitted work (secret-looking files are skipped); `--from-head` starts from HEAD only, and `--base-from <name>` starts from that session's worktree. If spawn reports **STARTUP DIALOG**, see `references/recovery.md`.
3. **Guard:** `$SKILL_DIR/scripts/guard.sh snapshot --run $RUN`.
4. **Assign:** write `$RUN/<name>/assignment.md` from `references/assignments.md`.
5. **Dispatch** in the background: `$SKILL_DIR/scripts/dispatch-all.sh --run $RUN` dispatches every live session you own in parallel and prints their reports in order. Pass names for a subset, or use `dispatch.sh --name <name>` for one.
6. **Settle.** Run `guard.sh verify`, then `delta.sh --state <state_dir> --out <state_dir>/delta.patch`. Judge the delta, never the report alone. A rejected delta goes back as `dispatch.sh --fix`.
7. **Review** per `references/review.md`, sized to risk.
8. **Integrate, validate and finish** per `references/integration.md`.

## Invariants (and why)

- **Never answer a dialog.** Never type into a pane that shows a trust or approval dialog: the Enter of a prompt would answer it on the user's behalf. The scripts check the screen first, because Herdr can report such a pane as idle.
- **Never overwrite later edits.** `integrate.sh` refuses a file that changed after its baseline; those changes belong to the user or to another integration.
- **"Done" is not proof.** A verified delta, a clean guard check, and checks you ran yourself are the proof.
- **Ports, databases and full suites run once,** by the principal, after integration, because concurrent runs collide. Sessions run fast, targeted checks.
- **No team state in the repository, and none left behind.** It lives under `$RUN`, and `cleanup.sh --run $RUN --finish` deletes `$RUN` once every session is cleaned. `cleanup.sh --prune` removes leftovers of abandoned runs; it never deletes a worktree.
- **One principal, at most one sibling.** Only the principal touches the user's checkout, commits and pushes. A sibling acts only on its slice and on the sessions it opened.
- **Only 5h windows.** Weekly quota never enters a decision.

`$SKILL_DIR/scripts/status.sh --run $RUN` prints both windows, both leads, every session grouped by owner, alerts, and what still needs a decision. Use it instead of reading `state.json`.

References:
- `assignments.md`: sibling, helper and reviewer templates;
- `review.md`: risk tiers and cross-review;
- `integration.md`: integrating in two levels, validate, commit, push, cleanup, report;
- `recovery.md`: dialogs, stalled sessions, guard violations, quota, panel and handoff, compaction.
