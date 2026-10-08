# Review policy

Read this file once the first candidate delta exists. Size the review to the risk of the change, not to the number of workers.

## Risk tiers

| Tier | Examples | Review |
|---|---|---|
| Low | Localized change, no contract or behavior change, existing tests cover it | You read the delta and run the checks. No reviewer. |
| Medium | Behavior or contract change, new public surface, non-trivial logic | Cross-review: the other provider reviews the delta. |
| High | Money or financial math, authorization, irreversible migrations, destructive operations, security boundaries | Cross-review plus the arbiter (third reviewer), before integration. |

A reviewer is always a different session from the author. Your own reading does not count as independent review for medium or high risk. If no independent session is available, say so in the final report and state how that limits readiness.

## Cross-review

Prefer an idle implementer of the other provider over a new session, because a new session costs context. Use one with no pending work, and send it the reviewer template through `dispatch.sh --message`. Note that a reused implementer keeps its full access. If you need a dedicated read-only reviewer, spawn one in the author's worktree:

```bash
$SKILL_DIR/scripts/spawn.sh --run $RUN --name rev --provider <the non-author provider> --role reviewer --review-of <author>
```

Write `$RUN/rev/assignment.md` from the reviewer template, then dispatch it. Afterwards, prove the review changed nothing. Run `delta.sh` into a separate file, so the reviewed artifact is never overwritten:

```bash
$SKILL_DIR/scripts/delta.sh --state $RUN/<author> --out $RUN/<author>/delta.after-review.patch
cmp -s $RUN/<author>/delta.patch $RUN/<author>/delta.after-review.patch || echo "reviewer changed the worktree"
```

If the files differ, discard the verdict, keep both patches, and investigate before going on.

## Third reviewer (arbiter)

Add one third session only when one of these holds:

1. The change is high risk, and the cross-review is done.
2. A blocking finding is disputed by the author after one fix round.
3. Only one implementer ran and the change is medium or high risk. In that case the arbiter is the only independent review.

Rules:

- Use the provider that did not author the change. If only one provider is available, use it in a fresh session, never the author's own session.
- Spawn it with `--role reviewer`. Its read-only profile, plus the before/after comparison above, keeps it honest.
- It counts against the cap while it is open. Close it with `herdr pane close <pane>` once its report is in, unless a follow-up round is planned.
- Two implementers plus one reviewer makes three sessions. A fourth session is only for a second reviewer on high-risk work.

## Handling findings

- **Blocking:** send it to the implementation owner as a fix round (`dispatch.sh --message`), quoting the finding. Then re-run `delta.sh` and review only what changed. Allow at most two fix rounds; after that, stop and report to the user.
- **Non-blocking:** list them in the final report. Do not fix them unless the acceptance criteria require it.
- **"No findings":** record it as a review that happened, naming the reviewer and the delta it covered.
