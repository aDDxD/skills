# Review policy

Read this file once the first candidate delta exists. Size the review to the risk of the change, not to the number of sessions.

There is no second subscription to cross-review, so independence comes from **a fresh session that never saw the author's context**, and where possible **a different model** from the author. Your own reading does not count as independent review for medium or high risk.

## Risk tiers

| Tier | Examples | Review |
|---|---|---|
| Low | Localized change, no contract or behavior change, existing tests cover it | The lead reads the delta and runs the checks. No reviewer. |
| Medium | Behavior or contract change, new public surface, non-trivial logic | One dedicated read-only reviewer: the provider's reviewer model (Sonnet on Claude, a fresh Sol on Codex). |
| High | Money or financial math, authorization, irreversible migrations, destructive operations, security boundaries | Two independent reviewers of different models, before integration: the reviewer model plus the lead model (Opus or Sol) in a fresh session. |

A reviewer is always a different session from the author. If no independent session is available (the window is out, or below the reserve and the change cannot wait), say so in the final report and state how that limits readiness.

## Who reviews what

- **A helper's delta:** a dedicated read-only reviewer. Reused helpers keep their full access, so do not use one as a reviewer for medium or high risk.

  ```bash
  $SKILL_DIR/scripts/spawn.sh --run $RUN --name rev --role reviewer --review-of <author> [--model M]
  ```

  The default model is `HERDR_SINGLE_CLAUDE_REVIEWER_MODEL` or `HERDR_SINGLE_CODEX_REVIEWER_MODEL`. For the second high-risk reviewer, pass `--model` with the lead model, or any model of the provider other than the author's.
- **Your own changes as lead:** write `git -C $REPO diff > $RUN/lead.patch` and open a read-only reviewer of the lead. It runs in the user's checkout with the read-only access profile, and its assignment points at `$RUN/lead.patch`:

  ```bash
  $SKILL_DIR/scripts/spawn.sh --run $RUN --name rev-lead --role reviewer --review-of lead [--model M]
  ```

  Skip the "prove it changed nothing" check below for this reviewer; run `guard.sh verify` and `git -C $REPO diff | cmp -s - $RUN/lead.patch` instead.

Reviewers use `HERDR_SINGLE_HELPER_EFFORT` (default `xhigh`); `--effort` overrides it for that session.

After a review in an author's worktree, prove it changed nothing. Run `delta.sh` into a separate file, so the reviewed artifact is never overwritten:

```bash
$SKILL_DIR/scripts/delta.sh --state $RUN/<author> --out $RUN/<author>/delta.after-review.patch
cmp -s $RUN/<author>/delta.patch $RUN/<author>/delta.after-review.patch || echo "reviewer changed the worktree"
```

If they differ, discard the verdict, keep both patches, and investigate before going on.

## Handling findings

- **Blocking:** send it to the owner as a fix round (`dispatch.sh --fix`), quoting the finding. Then re-run `delta.sh` and review only what changed. If the fix round fails too, take the problem yourself or give it to a stronger model of the same provider; do not loop.
- **Non-blocking:** list them in the final report. Do not fix them unless the acceptance criteria require it.
- **"No findings":** record it as a review that happened, naming the reviewer, its model and the delta it covered.

Close dedicated reviewers once their report is in.
