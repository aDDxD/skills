# Integration, validation, commit and push

Read this file before the first integration.

## Integrate

First run `$SKILL_DIR/scripts/guard.sh verify --run $RUN`. Do not integrate past a violation. Then, for each reviewed delta, integrate prerequisites first:

```bash
$SKILL_DIR/scripts/integrate.sh --state $RUN/<name> --patch $RUN/<name>/delta.patch          # check only
$SKILL_DIR/scripts/integrate.sh --state $RUN/<name> --patch $RUN/<name>/delta.patch --apply  # writes files
```

- **Exit 0:** the patch applies, and every touched path still matches the baseline. The script writes working-tree files only. It stages nothing and commits nothing.
- **Exit 3:** a touched path changed after the baseline, or the patch no longer applies. Stop, show the user the conflicting paths, and decide with them. Never force a patch.
- Never integrate a delta while its worker may still be writing. Wait for `dispatch.sh` to return.
- After `--apply`, that worker's baseline moves forward to the integrated state. A later fix round from the same worker therefore produces a delta of only the new work, which integrates on top of the earlier one.

## Validate

Run this repository's checks yourself, in the user's checkout, after integration. Record each result with `progress.sh check` so the panel and a successor lead see it. Take them from its instruction files and manifests, as `run-init.sh` listed them. Escalate by risk: targeted tests first, then the broader gates the repository defines. This is also where suites that bind ports or use shared services run, once.

Record every command with its exit code. A check you did not run is "not run", never "passed". If a check fails, send the failure to the owner of the file as a fix round. Do not hand-edit around it.

## Commit (only if commit_authorized in state.json)

1. Run `guard.sh verify` again just before committing.
2. If the current branch is the default branch shown by `run-init`, create `herdr-duo/<short-slug>` from HEAD first, and say so in the report.
3. Commit only the paths this run integrated. The checkout may also hold the user's own uncommitted work, so never use `git add -A` or `git commit -a`.

   ```bash
   git add -- <integrated paths>
   git commit -m "<message>" -- <integrated paths>
   ```

   Listing the paths after `--` commits only those paths, even if other changes are staged.
4. Match the repository's message style (`git log -n 20`). End the message with the attribution trailer the host session specifies.
5. If a hook fails, fix the cause and make a new commit. Never use `--no-verify`, and do not amend unless asked.

## Push (only if push_authorized)

```bash
git push -u origin <branch>
```

No force push. Never push to the default branch unless the user named it. Merge, PR and deploy each need their own explicit request.

## Cleanup

Close a strong session right after its delta is integrated, not at the end of the run. Close reviewers once their report is in. At the end, for each remaining session this run created:

```bash
$SKILL_DIR/scripts/cleanup.sh --run $RUN --name <name>
```

It closes the pane. A worktree still used by a live escalated session is kept until that session is cleaned. It removes the worktree only when the worktree's current delta is empty or identical to what was integrated. Otherwise it refuses (exit 8) and saves the patch. Use `--discard` only after the user agrees to drop that work. Name every refused or kept worktree in the report. Never close panes this run did not create.

When the run is complete, close the status panel and mark the run finished:

```bash
$SKILL_DIR/scripts/cleanup.sh --run $RUN --finish
```

Worktree paths are stable per repository and worker name, so a name can be reused once its worktree is gone, and agents keep their folder-trust decision for that path.

## Report

Your final message covers:

- the changed files;
- every check, with its exit code;
- the reviews done and any limitation;
- escalations, with their reason, and lead handoffs (`status.sh` lists both);
- the guard result;
- commit and push status, with the branch name;
- worktrees kept, and why;
- open issues.
