# Recovery

Read this file when a script exits non-zero, or a session misbehaves.

## Startup dialog (`spawn.sh` reports STARTUP DIALOG, status needs_approval)

The agent is showing a folder-trust or approval dialog. Do not answer it: no keys, no prompt. Tell the user which pane it is and what it asks, and let them decide in that pane.

When they confirm they have answered it, run:

```bash
$SKILL_DIR/scripts/spawn.sh --run $RUN --name <name> --recheck
```

Trust is remembered per path, and worktree paths are stable per repository and session name, so this is normally a one-time event. Codex applies trust at the main repository root, so a repository the user already trusts in Codex does not ask. Claude Code asks once per worktree path. If the user declines, close that pane and take its work yourself; there is no other subscription to route it to.

## dispatch.sh exit codes

| Exit | Meaning | Action |
|---|---|---|
| 5 | Settled, but no report block was found | Run `dispatch.sh --message "Repeat only your final report block."` once. If it is still missing, read `herdr agent read <name> --source recent-unwrapped --lines 120`. |
| 6 | Blocked, or NOT SENT because a dialog is on screen | Read the pane, then ask the user. Never answer the dialog yourself. |
| 7 | Timeout or stall | The prompt may already have been delivered. Inspect with `herdr agent get` and `agent read` before acting, and never resubmit blindly. If it is still working, run `herdr agent wait <name> --timeout <ms>` in the background. |

## Guard violation (`guard.sh verify` exits 4)

A ref, HEAD, branch or git config changed. It was either a worker, or the user working in parallel. Stop integrating. Show the user the violation lines, and find out which worker did it from its transcript. Do not undo anything yourself, because reverting refs is destructive. Continue only after the user decides.

## A session failed twice

Take the problem yourself, or continue in the same worktree with a stronger model of the same provider: `spawn.sh --run $RUN --name <new> --model <M> --continue-from <name>` (close the old pane first). Do not loop on fix rounds.

## Refusals

- "not the lead of this run": this pane was handed off or never led the run; stop.
- "this run uses only <provider>": herdr-single never starts a session on the other subscription. Use a model of the run's provider, or use herdr-duo for work that needs both.

## Quota, rate limit or provider failure

Helpers share the lead's window, so a helper that hits the limit means the whole run is about to park. Preserve the partial work first: run `delta.sh` for that session, once it has settled. Integrate what is sound, write a `progress.sh note` naming the partial delta and what remains, and let the run park; continue after the reset. Do not retry in a loop or set up paid access.

- **Quota line shows `?`:** the source is missing. Claude's comes from the Herdr usage bar (`~/.claude/herdr-usagebar/claude-limits-latest.json`, or `HERDR_SINGLE_CLAUDE_LIMITS`); Codex's from `$CODEX_HOME/sessions`. A working pane's own figure is the fallback. With an unknown window `quota.py suggest` allows only 2 helpers. Never substitute weekly data or invent a value.

## Worker went out of scope

If a worker wrote outside its owned files or its worktree, stop it with `herdr agent send-keys <name> esc` while it is working. Keep its worktree and delta, run `guard.sh verify`, and reassign the owned files with a fresh assignment. Report the incident.

## Push fails: could not read Username

Symptom: `run-init.sh --push` prints `push_check: FAILED (credentials are not available to git for https ...)`, or git reports `could not read Username for 'https://...': terminal prompts disabled`.

Cause: `origin` is an https URL and git has no credential helper. The scripts run git with `GIT_TERMINAL_PROMPT=0`, so git fails instead of asking for a username.

Fixes, for the user to choose. Do not apply either one yourself, because both change git configuration or the remote, which `guard.sh verify` watches:

- If an SSH key exists (`~/.ssh/id_*.pub`): `git remote set-url origin git@github.com:OWNER/REPO.git`.
- Otherwise: `gh auth setup-git`, which installs a credential helper for https.

After the user applies a fix, rerun `run-init.sh --push` to confirm `push_check: ok`. Do not retry the push in a loop.

## Effort settings

A fresh successor lead inherits the lead's recorded effort, translated per CLI (`ultra` becomes Claude `max`). If exact-session detection cannot read it, supply the actual effort with `run-init.sh --lead-effort <level>` at startup. Helpers use `HERDR_SINGLE_HELPER_EFFORT` (default `xhigh`); `spawn.sh --effort <level>` overrides either role for one session. Check the printed launch arguments when effort differs from what you expected.

## Cleanup and abandoned runs

`cleanup.sh --run $RUN --finish` refuses open sessions (exit 8): integrate their work and clean each session with `--name <name>` first. Finish prints the final status, closes the panel and deletes `$RUN`. Write the final report from that output; do not try to reopen the deleted run. Use `--keep-run` when you need the finished files for inspection.

For abandoned leftovers, run `cleanup.sh --prune --dry-run`, inspect its list, then run `cleanup.sh --prune`. It removes run directories without deleting worktrees. Runs with existing worktrees are kept: recover and integrate those before normal session cleanup. A finished run deleted by `--finish` needs no recovery or pruning.

## Panel, parking and resume

- **PARKED** (panel, `status.sh`, or `handoff.sh` exit 4 with the reset time): the run's 5h window is out. The run waits with its state intact; there is no other subscription to take over. As the lead, checkpoint with `progress.sh note` and stop. At the reset the panel resumes the run. With `HERDR_SINGLE_LEAD_RESUME=off`, or without the panel, the user asks any lead of the same provider to resume it (SKILL.md, Resume a run).
- **Parked on a limit message the sensor did not confirm:** the panel parks until the known reset, else for 30 minutes, then tries again. A lead that still shows the limit is parked again.
- **Resume in place:** the same lead pane gets a short prompt to continue after the reset. It keeps its context; it still follows Resume a run, starting with `status.sh`.
- **Fresh lead:** when the lead's pane is gone (or `HERDR_SINGLE_LEAD_RESUME=fresh`, or a lead passed the run on with `--reason "context full"`), a new lead of the same provider starts below the old pane, at the model and effort snapshotted in `lead.json` at run creation. A recorded model of the other provider, or Astra, falls back to the configured lead model.
- **Panel pane closed by accident:** split a pane and restart it: `herdr pane run <pane> "$SKILL_DIR/scripts/panel.sh --run $RUN"`. Without the panel there is no automatic parking or resume.
- **A script says "this pane is not the lead":** a handoff happened. Stop and do nothing more in this run. If the user wants this pane to lead again, they ask for it, and you run `handoff.sh --run $RUN --adopt` (the pane must run the run's provider).
- **The successor shows a startup dialog:** the panel shows it and waits. The user answers it in the successor's pane; the panel then delivers the resume prompt.
- **Successor stops after a status update or dispatch:** follow the autonomous continuation and goal recovery instructions in SKILL.md, Resume a run. Inspect existing panes and collect their results; do not request fresh authorization for the original task or create duplicate workers.
- **handoff.lock left behind:** a handoff was interrupted. Check `lead.json` and `herdr agent list`, then remove `$RUN/handoff.lock`.

## Native goal transfer fallback

Inspect `$RUN/goal-native.json` and `$RUN/goal-transfer.json`. `verified` means the successor's session contains the restored goal; `unconfirmed` means input may have been delivered, so query the native goal before retrying. `existing_goal` preserves a goal already present in the new pane. `needs_budget_tool` requires restoring the known remaining allowance through the native tool before work, since `/goal` has no budget parameter. Never write the provider's SQLite database or transcript to activate a goal. Unsupported storage/commands fall back to the ordinary resume prompt and portable checkpoint; do not interrupt existing workers.

## Context compaction

Follow "Resume a run" in SKILL.md. Rebuild your picture from these, and do not start duplicate workers because conversation context is missing:

- `status.sh --run $RUN`: the window, the lead and whether it is parked, sessions, status, fix rounds, alerts, open decisions;
- `$RUN/<name>/baseline.json` and the delta files;
- `herdr agent list`;
- `guard.sh verify`.

If you lost the `RUN` path, the newest run for this repository is under `${XDG_STATE_HOME:-~/.local/state}/herdr-single/runs/<repo>-<hash>/`.
