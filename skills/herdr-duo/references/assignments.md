# Assignment templates

Write each assignment to `$RUN/<name>/assignment.md`. `dispatch.sh` sends the worker a one-line pointer to it, so all detail lives in the file. Fill every field with concrete paths and commands for this repository. The worker has not seen the conversation.

## Implementer

```markdown
# Assignment: <name>

Task: <what to build or fix, 2-4 sentences, including why>
Acceptance criteria:
- <observable outcome>

Worktree: <absolute path>. It is a detached copy of the user's checkout; your edits are collected from here.
Owned files: <paths you may create or edit>
Read-only context: <paths, docs, contracts>
Other workers own: <paths you must not touch>
Checks you may run: <exact fast, targeted commands, e.g. a single test file, typecheck, lint on owned files>

Rules (you run with broad permissions; these are not optional):
- Work only inside your worktree. The only file outside it you may read is this assignment.
- Never run git commands that write: add, commit, stash, checkout, switch, branch, reset, rebase, merge,
  cherry-pick, push, tag, worktree, config. Read-only git (status, diff, log, show) is fine.
- Do not install, upgrade or remove dependencies unless you own the lockfile and the task requires it.
- Do not start servers on fixed ports, use shared databases or services, or run full or end-to-end suites;
  the lead runs those after integration.
- Do not deploy or touch production, credentials, authentication, billing or permissions.
- Do not spawn agents or invoke herdr-duo.
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

```markdown
# Review: <reviewer name> reviews <author name>

You are a read-only reviewer. Do not edit files. Do not run git commands that write.
Your working directory is the author's worktree. The change under review is in:
<absolute path to $RUN/<author>/delta.patch>
Acceptance criteria: <list>
Risk focus: <e.g. money arithmetic, authorization checks, migration reversibility>

Report only actionable findings. Give each one a file:line, its impact and the evidence.
Mark each finding blocking or non-blocking. End with exactly:
STATUS: findings | no-findings
FINDINGS: <numbered list, or none>
```

## Follow-ups

Reuse the live session: `dispatch.sh --run $RUN --name <name> --message "<text>"`. Keep the message short and refer back to the assignment, for example: "Same assignment and rules. Fix blocking finding 2 from the review: <quote>. End with the report block." Do not resend the whole assignment.
