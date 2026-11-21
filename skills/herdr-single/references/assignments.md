# Assignment templates

Write each assignment to `$RUN/<name>/assignment.md`. `dispatch.sh` sends the session a one-line pointer to it, so all detail lives in the file. Fill every field with concrete paths and commands for this repository. The session has not seen the conversation.

## Helper

```markdown
# Assignment: <name>

Task: <what to build, fix, find or check, 2-4 sentences, including why>
Acceptance criteria:
- <observable outcome>

Worktree: <absolute path>. It is a detached copy; your edits are collected from here.
Owned files: <paths you may create or edit, or "none: read-only task">
Read-only context: <paths, docs, contracts>
Others own: <paths you must not touch>
Checks you may run: <exact fast, targeted commands, e.g. a single test file, typecheck, lint on owned files>
Skills you may use: <optional: skill names and what for>

Rules (you run with broad permissions; these are not optional):
- Work only inside your worktree. The only file outside it you may read is this assignment.
- Never run git commands that write: add, commit, stash, checkout, switch, branch, reset, rebase, merge,
  cherry-pick, push, tag, worktree, config. Read-only git (status, diff, log, show) is fine.
- Do not install, upgrade or remove dependencies unless you own the lockfile and the task requires it.
- Do not start servers on fixed ports, use shared databases or services, or run full or end-to-end suites;
  the lead runs those after integration.
- Do not deploy or touch production, credentials, authentication, billing or permissions.
- Do not spawn agents or invoke herdr-single or herdr-duo.
- If you need a file you do not own, or a rule blocks the task, stop and report it as blocked.
- Follow the repository's AGENTS.md / CLAUDE.md conventions.

When finished, end your reply with exactly this block:
STATUS: done | blocked | failed
CHANGED: <paths>
BEHAVIOR: <2-5 lines>
CHECKS: <command -> exit code, one per line>
FINDINGS: <remaining issues, or none>
```

## Reviewer

Used by a dedicated read-only reviewer: a fresh session of the run's subscription that never saw the author's context.

```markdown
# Review: <reviewer name> reviews <author name>

You are a read-only reviewer. Do not edit files. Do not run git commands that write.
The change under review is in:
<absolute path to the patch, e.g. $RUN/<author>/delta.patch or $RUN/lead.patch>
You have no other context: judge the patch against the criteria below, not against intentions.
Acceptance criteria: <list>
Risk focus: <e.g. money arithmetic, authorization checks, migration reversibility>

Report only actionable findings. Give each one a file:line, its impact and the evidence.
Mark each finding blocking or non-blocking. End with exactly:
STATUS: findings | no-findings
FINDINGS: <numbered list, or none>
```

## Follow-ups and fix rounds

Reuse the live session. Keep the message short and refer back to the assignment. Do not resend the whole assignment.

- A round you reject (failed checks, blocking finding, wrong behavior): `dispatch.sh --run $RUN --name <name> --fix "Same assignment and rules. Fix blocking finding 2 from the review: <quote>. End with the report block."`. If the second round fails too, take the problem yourself or give it to a stronger model of the same provider.
- Anything else (repeat the report, a clarification, a new task for the same session): `dispatch.sh --message "<text>"`. A new task gets a new `assignment.md` and a plain `dispatch.sh`.
