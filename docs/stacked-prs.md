# Stacked Pull Requests

Use **stacked PRs** by default. Unless the task is obviously a single concern, split it
into semantically meaningful, independently reviewable units that land as an ordered
chain of small PRs rather than one large PR — e.g. a refactor + a feature + a build
pipeline becomes three stacked PRs. Each PR in the stack must leave the repo green.

With `sky/scripts/` on your PATH (recommended: `PATH_add sky/scripts` in `.envrc`):

```bash
git stack-create [branch]    # create a child branch + PR off the current branch
git stack-restack            # sync the whole stack after a parent merges
```

Both commands require `GITHUB_TOKEN` or `GH_TOKEN` for GitHub API calls.

## Pushing changes

Do not rewrite published stack branches for ordinary changes — push review fixes and
follow-ups as new commits on top, with plain (non-force) pushes, so collaborators' local
checkouts keep fast-forwarding. PRs are squash-merged, so commit-level tidiness comes
from the merge, not from amending. Force pushes (`--force-with-lease`) are reserved for
restacking after a parent PR merges.

## Local checkouts of stack branches

Run `git config pull.rebase true` in your clone. Restacks force-push rewritten history;
with `pull.rebase` set, `git pull` replays only your local commits onto the new tip
(skipping already-applied ones).
