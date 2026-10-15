# Integration, validation, commit and push

Read this file before the first integration.

## Integrate

Integration has two levels. A sibling lead integrates its own helpers' deltas into **its worktree** (their baseline is that worktree, from `--base-from`). The principal integrates the sibling's slice and its own helpers' deltas into **the user's checkout**. `integrate.sh` targets the delta's recorded source and refuses a sibling that aims anywhere but its own worktree.

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

The principal runs this repository's checks, in the user's checkout, after integration. A sibling runs targeted checks in its worktree before reporting. Record each result with `progress.sh check` so the panel and a successor lead see it. Take them from its instruction files and manifests, as `run-init.sh` listed them. Escalate by risk: targeted tests first, then the broader gates the repository defines. This is also where suites that bind ports or use shared services run, once.

Record every command with its exit code. A check you did not run is "not run", never "passed". If a check fails, send the failure to the owner of the file as a fix round. Do not hand-edit around it.

## Commit (only if commit_authorized in state.json; principal only)

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

Reuse live sessions at safe task boundaries; close a helper as soon as you will not reuse it, so it stops holding a pane. Close reviewers once their report is in. A sibling closes the helpers it opened before reporting. At the end, for each remaining session this run created (the sibling included, once its slice is integrated):

```bash
$SKILL_DIR/scripts/cleanup.sh --run $RUN --name <name>
```

It closes the pane. A worktree still used by a live `--continue-from` session is kept until that session is cleaned. It removes the worktree only when the worktree's current delta is empty or identical to what was integrated. Otherwise it refuses (exit 8) and saves the patch. Use `--discard` only after the user agrees to drop that work. Name every refused or kept worktree in the report. Never close panes this run did not create.

Once all sessions are cleaned, the principal finishes the run:

```bash
$SKILL_DIR/scripts/cleanup.sh --run $RUN --finish
```

`--finish` refuses while sessions remain open (exit 8). It prints the final status, closes the panel, and deletes `$RUN`; no run files remain. Add `--keep-run` to retain the finished run for inspection. Preserve the command's output in the conversation and write the final report from it, because `status.sh` and the run files are unavailable after deletion.

For abandoned-run leftovers, inspect first, then prune:

```bash
$SKILL_DIR/scripts/cleanup.sh --prune --dry-run
$SKILL_DIR/scripts/cleanup.sh --prune
```

Prune removes finished or abandoned run directories; it never deletes worktrees and keeps runs whose worktrees still exist. Resolve those worktrees through normal integration and cleanup. Global quota history and `balance.json` remain outside run directories.

Worktree paths are stable per repository and worker name, so a name can be reused once its worktree is gone, and agents keep their folder-trust decision for that path.

## Report

Write the final message from the `--finish` output and the check results already recorded in the conversation. It covers:

- the changed files;
- every check, with its exit code;
- the reviews done and any limitation;
- how the work was split: the sibling's slice, helpers per subscription and model, and lead handoffs (included in the final status);
- the 5h windows shown in the final status;
- the guard result;
- commit and push status, with the branch name;
- worktrees kept, and why;
- open issues.
