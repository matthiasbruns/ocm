# Review evidence for open-component-model/ocm PR #2189

Reviewed head: `58cdd2ebf662110e73cf924287db2571f648de09`. Merge base: `7720e0813b1812489f479560cecbfa5fcd7988dd`.

This branch adds files under `.review/pr-2189/` only. It changes no file of the PR.

Both scripts need Ruby (stdlib only). `F2` also needs an authenticated `gh` and only sends GET requests. Exit codes: 0 = correct, 1 = reproduced, 2 = inconclusive.

## F1: the bump job gets empty bot secrets

`release.yaml` and `release-branch.yaml` call `release-bump-version.yaml` without passing secrets. GitHub's docs on reusable workflows say the caller must still pass an environment secret, otherwise it resolves to an empty string in the reusable workflow: <https://docs.github.com/en/actions/how-tos/reuse-automations/reuse-workflows>. With an empty `client-id` the token step fails, as in <https://github.com/open-component-model/ocm/actions/runs/44749897674>.

```sh
ruby .review/pr-2189/F1-reusable-workflow-secrets.rb .
```

| Tree | Result |
| --- | --- |
| PR head | exit 1, 4 problems (2 secrets x 2 callers) |
| Merge base | exit 0 |
| PR head + `F1-suggested-fix.patch` | exit 0 |

`F1-suggested-fix.patch` passes the two secrets by name and declares them as required in the reusable workflow. Apply it with `git apply .review/pr-2189/F1-suggested-fix.patch`.

## F2: the `pull-request` environment only allows `main`

`release.yaml` runs on `releases/vX.Y` and calls the bump job, which the PR moves into the `pull-request` environment. GitHub matches an environment's branch rule against the `GITHUB_REF` of the run. The script compares the branches each workflow has run on with the live branch policy of the environment its jobs use.

```sh
ruby .review/pr-2189/F2-environment-branch-policy.rb .
ruby .review/pr-2189/F2-environment-branch-policy.rb . --assume-policy 'pull-request=main,releases/v*'
```

| Tree | Result on 2026-11-20 |
| --- | --- |
| PR head | exit 1, 15 of 65 (job, branch) pairs rejected, all for the bump job on `releases/v0.42` to `releases/v0.56` |
| Merge base | exit 0, 0 of 65 rejected |
| PR head, policy assumed `main, releases/v*` | exit 0, 0 of 65 rejected |

## Limits

Both scripts check the workflow files and the live settings against GitHub's documented rules. Neither failure has been executed on GitHub Actions.
