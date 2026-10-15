# Review policy

Read this file once the first candidate delta exists. Size the review to the risk of the change, not to the number of sessions.

## Risk tiers

| Tier | Examples | Review |
|---|---|---|
| Low | Localized change, no contract or behavior change, existing tests cover it | The integrating lead reads the delta and runs the checks. No reviewer. |
| Medium | Behavior or contract change, new public surface, non-trivial logic | Cross-review by the other subscription. |
| High | Money or financial math, authorization, irreversible migrations, destructive operations, security boundaries | Cross-review by the other lead, plus a second independent reviewer before integration. |

A reviewer is always a different session from the author, and preferably the other subscription. Your own reading does not count as independent review for medium or high risk. If no independent session is available, say so in the final report and state how that limits readiness.

## Cross-review between the leads

The two leads come from different subscriptions, so they are each other's natural reviewers:
- **The sibling's slice:** the principal reviews it while integrating. For medium or high risk, add an independent reviewer from the principal's subscription.
- **The principal's own changes:** write `git -C $REPO diff > $RUN/lead.patch`. Send the sibling the reviewer template with `dispatch.sh --run $RUN --name <sibling> --message "<review assignment path>"` once it is between tasks, or open a dedicated reviewer.
- **A helper's delta:** a helper or reviewer of the other subscription. A reused helper keeps its full access, so prefer a dedicated read-only reviewer for medium or high risk:

```bash
$SKILL_DIR/scripts/spawn.sh --run $RUN --name rev --provider <the non-author subscription> --role reviewer --review-of <author> [--model M]
```

Choose the reviewer's model by risk: Haiku or Luna for routine medium-risk diffs, Opus or Sol (`--model`) for high risk. Reviewers are helpers and use `HERDR_DUO_HELPER_EFFORT` (default `xhigh`); `--effort` overrides it for that session.

After a review in an author's worktree, prove it changed nothing. Run `delta.sh` into a separate file, so the reviewed artifact is never overwritten:

```bash
$SKILL_DIR/scripts/delta.sh --state $RUN/<author> --out $RUN/<author>/delta.after-review.patch
cmp -s $RUN/<author>/delta.patch $RUN/<author>/delta.after-review.patch || echo "reviewer changed the worktree"
```

If they differ, discard the verdict, keep both patches, and investigate before going on.

## Handling findings

- **Blocking:** send it to the owner as a fix round (`dispatch.sh --fix`), quoting the finding. Then re-run `delta.sh` and review only what changed. If the fix round fails too, take the problem yourself or give it to a stronger model; do not loop.
- **Non-blocking:** list them in the final report. Do not fix them unless the acceptance criteria require it.
- **"No findings":** record it as a review that happened, naming the reviewer and the delta it covered.

Close dedicated reviewers once their report is in.
