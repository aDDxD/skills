# Recovery

Read this file when a script exits non-zero, or a session misbehaves.

## Startup dialog (`spawn.sh` reports STARTUP DIALOG, status needs_approval)

The agent is showing a folder-trust or approval dialog. Do not answer it: no keys, no prompt. Tell the user which pane it is and what it asks, and let them decide in that pane.

When they confirm they have answered it, run:

```bash
$SKILL_DIR/scripts/spawn.sh --run $RUN --name <name> --recheck
```

Trust is remembered per path, and worktree paths are stable per repository and worker name, so this is normally a one-time event. Codex applies trust at the main repository root, so a repository the user already trusts in Codex does not ask. Claude Code asks once per worktree path. If the user declines, close that pane and route its work to the other provider.

## dispatch.sh exit codes

| Exit | Meaning | Action |
|---|---|---|
| 5 | Settled, but no report block was found | Run `dispatch.sh --message "Repeat only your final report block."` once. If it is still missing, read `herdr agent read <name> --source recent-unwrapped --lines 120`. |
| 6 | Blocked, or NOT SENT because a dialog is on screen | Read the pane, then ask the user. Never answer the dialog yourself. |
| 7 | Timeout or stall | The prompt may already have been delivered. Inspect with `herdr agent get` and `agent read` before acting, and never resubmit blindly. If it is still working, run `herdr agent wait <name> --timeout <ms>` in the background. |

## Guard violation (`guard.sh verify` exits 4)

A ref, HEAD, branch or git config changed. It was either a worker, or the user working in parallel. Stop integrating. Show the user the violation lines, and find out which worker did it from its transcript. Do not undo anything yourself, because reverting refs is destructive. Continue only after the user decides.

## Escalation refused (`escalate.sh` exits 2)

- "no failed fix round yet": send one `dispatch.sh --fix` round first, or use `--cross-cutting` with evidence.
- "strong session ... is still live": finish that session's problem, integrate it and run `cleanup.sh` on it, then escalate. Never run two strong sessions in parallel.
- "already strong": strong sessions do not escalate further. Report the blocker.

If `escalate.sh` fails after closing the base pane, the work is still in the worktree and the attempt patch is saved. Start the strong session directly: `spawn.sh --run $RUN --name <new> --provider <p> --role implementer --tier strong --continue-from <worker>`.

## Quota, rate limit or provider failure

Preserve the partial work first: run `delta.sh` for that worker. Make sure the worker has settled. Then reassign the remaining work to the other provider, with an assignment that names the partial delta. Do not retry in a loop or set up paid access. A quota failure is not a reason to escalate to a strong model.

## Worker went out of scope

If a worker wrote outside its owned files or its worktree, stop it with `herdr agent send-keys <name> esc` while it is working. Keep its worktree and delta, run `guard.sh verify`, and reassign the owned files with a fresh assignment. Report the incident.

## Push fails: could not read Username

Symptom: `run-init.sh --push` prints `push_check: FAILED (credentials are not available to git for https ...)`, or git reports `could not read Username for 'https://...': terminal prompts disabled`.

Cause: `origin` is an https URL and git has no credential helper. The scripts run git with `GIT_TERMINAL_PROMPT=0`, so git fails instead of asking for a username.

Fixes, for the user to choose. Do not apply either one yourself, because both change git configuration or the remote, which `guard.sh verify` watches:

- If an SSH key exists (`~/.ssh/id_*.pub`): `git remote set-url origin git@github.com:OWNER/REPO.git`.
- Otherwise: `gh auth setup-git`, which installs a credential helper for https.

After the user applies a fix, rerun `run-init.sh --push` to confirm `push_check: ok`. Do not retry the push in a loop.

## Panel and lead handoff

- **Panel pane closed by accident:** split a pane and restart it: `herdr pane run <pane> "$SKILL_DIR/scripts/panel.sh --run $RUN"`. Without the panel there is no automatic handoff.
- **A script says "this pane is no longer the lead":** a handoff happened. Stop and do nothing more in this run. If the user wants this pane to lead again, they ask for it, and you run `handoff.sh --run $RUN --adopt`.
- **The successor shows a startup dialog:** the panel shows it and waits. The user answers it in the successor's pane; the panel then delivers the resume prompt.
- **NO LEAD / stranded:** every provider ran out of quota. The run waits with its state intact. When a quota resets, the panel marks the lead active again; or the user opens any lead and asks it to resume the run (SKILL.md, Resume a run).
- **handoff.lock left behind:** a handoff was interrupted. Check `lead.json` and `herdr agent list`, then remove `$RUN/handoff.lock`.

## Context compaction

Follow "Resume a run" in SKILL.md. Rebuild your picture from these, and do not start duplicate workers because conversation context is missing:

- `status.sh --run $RUN`: sessions, tiers, status, fix rounds, escalations, open decisions;
- `$RUN/<name>/baseline.json` and the delta files;
- `herdr agent list`;
- `guard.sh verify`.

If you lost the `RUN` path, the newest run for this repository is under `${XDG_STATE_HOME:-~/.local/state}/herdr-duo/runs/<repo>-<hash>/`.
