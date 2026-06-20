# Development workflow

FiFO is mostly worked on solo, directly on `main`. That's still fine for small
fixes. But the repo has a **Claude auto code-review** GitHub Action
(`.github/workflows/claude-code-review.yml`) that only runs on **pull requests** —
so anything you'd like a review pass on should go through a short-lived branch and
a PR. This is a light habit, not an enforced rule.

## The loop

```sh
git switch -c short-topic-name      # branch off main
# ... edit, then commit as usual ...
git commit -am "what changed"
git pr                              # push branch + open a PR against main
# Claude auto-review posts on the PR; address anything, push more commits
git prmerge                         # squash-merge and delete the branch
git switch main && git pull         # sync local main
```

Direct to `main` (no review) is still available when you want it:

```sh
git commit -am "..." && git push
```

## Helper aliases

`git pr` and `git prmerge` are convenience git aliases (they shell out to `gh`):

- **`git pr`** — `git push -u origin HEAD` then `gh pr create --fill --base main`
  (fills title/body from your commits). Extra args pass through to `gh pr create`,
  e.g. `git pr --draft` or `git pr --title "..."`.
- **`git prmerge`** — `gh pr merge --squash --delete-branch` for the current
  branch's PR.

They are stored in this clone's local config. To set them up in a fresh clone, or
globally for all repos, run:

```sh
git config alias.pr '!f() { git push -u origin HEAD && gh pr create --fill --base main "$@"; }; f'
git config alias.prmerge '!gh pr merge --squash --delete-branch'
# add --global to either to make it apply everywhere
```

(`gh` must be authenticated: `gh auth status`.)

## When the auto-review runs

The review fires on PR **opened / updated / reopened / marked ready**. It runs the
`code-review` plugin against the PR diff and comments inline. It uses the
`CLAUDE_CODE_OAUTH_TOKEN` repo secret and counts against the Claude account quota,
so each PR (and each push to an open PR) is a billed run.

You can also invoke Claude on demand by mentioning **`@claude`** in any issue or
PR comment (`.github/workflows/claude.yml`).
