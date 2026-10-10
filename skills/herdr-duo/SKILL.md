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
2. `$SKILL_DIR/scripts/run-init.sh --repo <repo> --goal "<one line>" [--lead-model <actual model>] [--commit] [--push]`. Pass `--commit` or `--push` only if the user's **initial** request explicitly asked for that. The script prints `RUN`, `REPO`, the branch and default branch, uncommitted counts, the repository's instruction files, dependency directories, and stale worktrees. It also records your pane as the run's lead and opens the **status panel** to the right of it (see "Panel and lead handoff"). Model detection reads Herdr metadata or the exact session's transcript; use `--lead-model` when unavailable, supplying the user's actual model rather than choosing a new one. Pass `--no-panel` only if the user asked for no panel.
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
- Balance providers by their current 5h quota as described below, keeping the other provider available for cross-review; a fixed 50/50 worker split is not required. `spawn.sh` places panes for you: it splits the largest pane the run owns along its longer side and opens a new tab ("<repo> 2", ...) when no pane has room (`HERDR_DUO_MIN_PANE_COLS`, default 70, and `HERDR_DUO_MIN_PANE_ROWS`, default 18). It never splits your pane or panes the run did not create.
- **Strong workers/reviewers never scale horizontally.** At most one strong worker or reviewer session is live per run; `spawn.sh` and `escalate.sh` refuse a second. The lead has its own model choice and does not occupy this slot. Plan a task as strong from the start only when it needs cross-cutting reasoning that cheap models get wrong, for example a financial rule spread over several files. Otherwise strong sessions come only from escalation (below).
- **Reviewers** are read-only and on demand, as set out in `references/review.md`. Close them once their report is in.
- Reuse live base sessions for follow-ups (`dispatch.sh --message`) and fix rounds (`dispatch.sh --fix`). Close sessions you will not reuse.
- Apply the quota policy below first. When current 5h headroom is similar or unknown, prefer Haiku for localized, mechanical, test and doc work, and Luna for multi-file logic with invariants or debugging with an unclear root cause. A change is reviewed by the provider that did not write it. If a provider is unavailable or rate-limited, send its work to the other.
- Do not implement routine work yourself. If the workers and the escalation fail, finish the deterministic checks and report the blocker.

### Balancing provider quota

The lead balances workers using **only the remaining quota in each provider's current 5-hour window**. Never use weekly quota, weekly reset times or a weekly consumption target to choose a provider, reserve capacity or throttle workers. The goal is to balance consumption of the current windows and extend useful session time as far as possible.

- Before allocating workers and at each new wave, compare the latest available 5h remaining percentages shown by the panel or Herdr usage data. If Codex has more headroom, favor Codex workers (Luna, or Sol when strong-tier rules permit); if Claude has more, favor Claude workers (Haiku, or Sonnet when permitted). Reassess as the windows are consumed or reset.
- Quota preference takes precedence over the task-type defaults above, but does not justify extra workers, strong-tier escalation, changing the lead's model or skipping required cross-review. Allocate useful work to the provider with more headroom; do not manufacture work to equalize percentages.
- Apply changes to new assignments at safe task boundaries. Reuse suitable live sessions and let in-flight work finish rather than restarting it merely to rebalance. If either 5h value is unknown, do not substitute weekly data or invent a value; use task fit and available sessions until current-window data is available.
- An actual usage-limit error still makes a provider unavailable, whatever its cause. Follow `references/recovery.md`; this is failure recovery, not weekly-quota planning.

### Escalation to Sol or Sonnet

Escalate a base worker's task only when one of these holds:

1. **Two failed rounds on the same problem**: the initial round plus one `dispatch.sh --fix` round, each failed by its own report, by your checks, or by a blocking review finding. A failure caused by your assignment (missing context, wrong ownership, unclear criteria) does not count: fix the assignment and resend.
2. **Cross-cutting reasoning** turned out to be required mid-task (`--cross-cutting`, with the evidence in `--reason`).

Never escalate mechanical work, test adjustments or documentation; base workers handle those well. For those, after two failed rounds, stop and report.

```bash
$SKILL_DIR/scripts/escalate.sh --run $RUN --name <worker> --reason "<what failed twice, in one line>"
```

It saves the failed attempt as a patch, closes the base session, and starts a new, dedicated strong session in the same worktree (by default from the other provider, a different model family). Write its assignment from the escalation template in `references/assignments.md`: only the failing problem, narrowly scoped. Dispatch it, review it like any change (the reviewer is the other provider), integrate it, and close it with `cleanup.sh` right away, so it does not stay live and use up quota. A strong session gets at most one fix round. If it still fails, stop and report the blocker; there is no further escalation.

## Panel and lead handoff

The panel is a script, not an agent: it uses no quota. It shows your checklist, what you are doing now, every session, the quota left per provider, the last checks, git and CI. It also watches your own quota:

The initial lead model defines a persistent handoff band: **Opus ↔ Astra** or **Sonnet ↔ Sol 6.1**. `run-init.sh` records the initial model, band and both destinations in `lead.json`; subsequent handoffs and manual adoption preserve that band. A later model switch in the current pane does not redefine the initial choice. The panel and `status.sh` show the current model, band and destinations. Luna/Haiku workers and their single escalation to Sonnet/Sol follow the existing rules independently.

Destination defaults are `HERDR_DUO_SOL_MODEL` / `HERDR_DUO_SONNET_MODEL` for Sonnet–Sol and `HERDR_DUO_LEAD_ASTRA_MODEL` (default `gpt-6-astra`) / `HERDR_DUO_LEAD_OPUS_MODEL` (default `claude-opus-5-5`) for Opus–Astra. Explicit `HERDR_DUO_LEAD_CODEX_MODEL` / `HERDR_DUO_LEAD_CLAUDE_MODEL` override their provider's destination; `HERDR_DUO_LEAD_CODEX_EFFORT` defaults to the configured Sol effort. Destinations and effort are snapshotted at run creation, so subsequent configuration changes apply to new runs. An unknown model leaves its band unresolved: do not silently choose a lower band. Resolve it with `handoff.sh --run $RUN --reason "quota low" --lead-model <original model>` before switching. Old runs without destination snapshots retain the previous configured Sol/Sonnet behavior, shown as `legacy`.

- At `HERDR_DUO_LEAD_WARN_PCT` (default 10%) of your 5h quota left, scripts you run print **LEAD QUOTA LOW**. Then write a `progress.sh note` with your next steps, and pass the lead at a safe point (not in the middle of an integration): `handoff.sh --run $RUN --reason "quota low"`. After a handoff you are no longer the lead: stop, and do nothing more in this run.
- If you run out while idle (at most `HERDR_DUO_LEAD_HANDOFF_PCT` left, or a limit message on your screen), the panel hands off by itself. The successor is a fresh session of the other provider in the recorded band (`HERDR_DUO_LEAD_FALLBACK=auto|codex|claude|off` selects the provider, not the band). It opens below your pane and resumes the run. A provider that already ran out in this run is not tried again for 5 hours; then the run waits for the user. If the selected model is unavailable, report the failure rather than switching bands automatically.
- Your pane is never typed into. A lead fence keeps an old lead from acting: every script that changes the run refuses any pane but the current lead.

The handoff is only as good as what you record. Keep the panel and the successor informed with `progress.sh`; each call costs one short command:

```bash
$SKILL_DIR/scripts/progress.sh --run $RUN plan "<step 1>" "<step 2>" ...   # once, after planning; again if the plan changes
$SKILL_DIR/scripts/progress.sh --run $RUN step <n> active|done|failed
$SKILL_DIR/scripts/progress.sh --run $RUN check "<label>" <exit code> "<summary, e.g. 256/268 passed>"
$SKILL_DIR/scripts/progress.sh --run $RUN note "<decision or next step a successor must know>"
```

Write a `note` at each milestone: a plan decision, an integration, a wave finished, a dispatch you are about to wait on. Record a genuinely required unanswered decision as `waiting for user: <question>` with the reason it blocks work. Optional questions and already authorized actions must not become blockers; record the chosen assumption or existing authorization instead. Write steps in the user's language.

### Resume a run

When you were started to resume a run (a handoff prompt, or the user asks after compaction or a stop):

1. Run `preflight.sh`, then `status.sh --run $RUN`. A handoff successor is already the lead (`you are the lead`). Only if it says `you are NOT the lead` and the user asked you to take over, run `handoff.sh --run $RUN --adopt`.
2. Read `$RUN/handoff.md`, `progress.json`, `state.json` and `$RUN/goal.json` if present. The successor inherits the original task, user constraints and recorded authorization, including commit/push permissions; a handoff is a continuation, not a new approval request. These files are the durable run context; do not re-plan finished steps, and never spawn duplicates of live workers.
3. Run `guard.sh verify --run $RUN`.
4. Inspect every owned live worker pane and its assignment/report, including workers marked settled when a follow-up may still be running. Existing terminal processes belong to the run, not to the previous lead session. Reattach dispatched work with `dispatch.sh --run $RUN --name <name> --collect` in the background: it sends nothing, waits, and prints the report. Old shell-tool session IDs are not transferable; use durable files and Herdr pane state to recover their outcome. Never restart a suite, resend an assignment or spawn a replacement before checking the existing process.
5. Reconcile any `waiting for user` note against the latest request and existing authorization. Only a still-required missing decision or actual approval dialog blocks dependent work; continue independent work. Otherwise write a takeover note and immediately execute the next unfinished action. A status update or background dispatch is not the end of the task: collect results, resolve findings, validate, integrate and perform authorized delivery/cleanup until the acceptance criteria are met. Do not end with an offer to continue or wait for the user merely because leadership changed.
6. Restore goal continuity as described below; goal-tool availability must never block the work.

### Goal continuity across providers

The portable goal is `state.json.goal` plus `progress.json` and `$RUN/goal.json`. `handoff.sh` automatically captures the old leader's native goal by its exact Herdr session ID into `$RUN/goal-native.json`: read-only Codex SQLite or Claude transcript records, with portable fallback if the private format is unavailable. It never types into the old leader. Before delivering the resume prompt, it restores an active goal with `/goal <objective>` in the ready successor and checks the new session record. The command also points at `$RUN/lead-resume.md`, because setting a goal immediately starts work. `$RUN/goal-transfer.json` records verification or fallback; an ambiguous submission is not repeated. A plain task title never implies permission to create a native goal. Paused, blocked, completed or budget-exhausted goals are not reactivated. A native `usage_limited` goal can resume when switching to the other provider: provider quota exhaustion is the reason for that handoff, and does not cancel the task or renew its token budget. Codex `/goal` cannot carry a token budget: a budgeted goal uses the successor's native tool with only the remaining allowance, rather than silently becoming unlimited. Provider formats are private; recovery must still work when they change. When the user explicitly requests a goal or goal inheritance, record its objective, acceptance criteria, remaining work, status and native budget snapshot (if available) with:

```bash
$SKILL_DIR/scripts/progress.sh --run $RUN goal '<JSON object>'
```

Keep this snapshot current at milestones and before a planned handoff. Include user constraints/authorization references and concrete next actions; never include credentials or private task data unnecessarily. The command accepts an object and stamps `updated_at`; it does not change native goal state. Automatic quota handoff relies on the last durable checkpoint, so update before quota exhaustion.

On takeover, query an available native goal tool first. Continue an existing matching goal; do not duplicate or complete it because the leader changed. If no active goal exists, recreate it only when the user explicitly requested a goal or its inheritance, using the durable objective and remaining criteria. Carry over a known remaining token budget, never reset it to the original total; if unavailable, preserve the recorded limit and usage as constraints without inventing a fresh allowance. Respect an explicit user pause. If the provider has no equivalent tool, maintain the portable goal and continue the same task autonomously. Mark the portable/native goal complete only after the entire delivery meets its criteria, including required CI and cleanup. A working worker, background test, review finding or incomplete delivery means work remains.

## Workflow

1. **Plan.** Write acceptance criteria, dependencies and file ownership per task. Each file has one writer. Shared contracts, lockfiles, schemas and generated files get exactly one writer. Record the steps with `progress.sh plan`.
2. **Spawn** each implementer: `$SKILL_DIR/scripts/spawn.sh --run $RUN --name luna --provider codex --role implementer --deps-auto`. Then the others the same way; placement is automatic (pass `--split-from <pane> --direction right|down` only to override it). Give each worker a short task-based name (`luna-api`, `haiku-docs`). Workers start from your current checkout, including uncommitted work; secret-looking files are skipped. Use `--from-head` to start from HEAD only. If spawn reports **STARTUP DIALOG**, see `references/recovery.md`.
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

- **One strong worker/reviewer at a time, closed when done.** Sol and Sonnet workers/reviewers work one narrow problem and close; the lead is independent of this limit.
- **One lead per run.** Only the pane in `lead.json` acts on the run. After a handoff, the previous lead stops.

`$SKILL_DIR/scripts/status.sh --run $RUN` prints every session with its tier, status and fix rounds, the live strong session, the escalations, and what still needs a decision. Use it instead of reading `state.json`.

References: `assignments.md` (assignment, escalation and reviewer templates), `review.md` (risk tiers, cross-review, the third reviewer), `integration.md` (integrate, validate, commit, push, cleanup, report), `recovery.md` (dialogs, blocked or stalled sessions, guard violations, quota, panel and handoff, compaction).
