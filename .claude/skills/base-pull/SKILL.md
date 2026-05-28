---
name: base-pull
description: Pull the latest `origin/<base-branch>` into the current worktree's branch — without checking the base branch out anywhere. Fetches `origin/<base>`, fast-forwards local `refs/heads/<base>` to match (so it stays in lockstep with origin and `/base-merge down` sees fresh content), then merges the local base ref into the current branch. Caller's worktree stays on its branch the entire time. Base branch is configurable via `.claude/workflow.config` (default `main`).
---

# base-pull — merge the shared base branch INTO the current branch

Pull the latest `origin/$WORKFLOW_BASE_BRANCH` down into the current worktree's feature branch. The base branch itself is never checked out anywhere — the caller's worktree stays on its branch the entire time.

Performs, in order:

1. Capture caller state; refuse if HEAD is on the base branch
2. Commit any pending work on the current branch
3. Push the current branch to `origin` (durable backup before any merge)
4. `git fetch origin $WORKFLOW_BASE_BRANCH`
5. Fast-forward LOCAL `refs/heads/$WORKFLOW_BASE_BRANCH` to match `origin/$WORKFLOW_BASE_BRANCH` (so local and origin base refs stay in lockstep — keeps `/base-merge down`, which reads the local ref, from seeing stale content)
6. Merge LOCAL `refs/heads/$WORKFLOW_BASE_BRANCH` into the current branch (`--no-ff`)
7. Report (no auto-push of the merge commit — that's the user's call)

## When to Use

Invoked when the user says things like:

- "pull base"
- "sync with base"
- "merge the base branch into this branch"

## Preconditions

- Caller is in a feature worktree (not on the base branch)
- The current branch has an `origin` remote
- Network reachable
- `.claude/workflow.config` exists (or the default `WORKFLOW_BASE_BRANCH=main` is acceptable)

## Execution Steps

### 0. Load workflow config

```bash
source "$(git rev-parse --show-toplevel)/.claude/scripts/_config.sh"
# $WORKFLOW_BASE_BRANCH and $WORKFLOW_MAIN_PATH are now set
```

### 1. Capture state and refuse the wrong starting branches

```bash
ORIGINAL_BRANCH=$(git rev-parse --abbrev-ref HEAD)
```

Refuse if `ORIGINAL_BRANCH` is `$WORKFLOW_BASE_BRANCH`. Hint: nothing to merge into — the base branch IS what you'd pull from. If they just want the local base-branch ref updated, suggest `git -C $WORKFLOW_MAIN_PATH fetch origin $WORKFLOW_BASE_BRANCH` directly.

### 2. Commit any pending work

Standard commit flow:

- `git status` + `git diff` to review what's pending
- `git log --oneline -5` to match the repo's commit-message style
- Conventional-commits message focused on the `why`
- Stage only the relevant files (no `git add -A` / `git add .`)
- Commit with whatever co-authorship trailer your project uses (or none)
- HEREDOC for the `-m` argument
- Never `--amend`, never `--no-verify`

**Skip this step when:** `git status` shows a clean tree AND `git log origin/$ORIGINAL_BRANCH..HEAD` is empty. Note the skip in the status update and proceed.

If the tree is clean but there are unpushed commits, skip the commit and go straight to push.

### 3. Push the current branch (backup)

```bash
git push origin "$ORIGINAL_BRANCH"
```

Abort the whole skill on failure. The feature branch should be safely at `origin` before we attempt the merge — that way if the merge produces conflicts we don't have to mentally track which work is committed locally vs published.

### 4. Fetch the base branch

```bash
git fetch origin "$WORKFLOW_BASE_BRANCH"
```

Refreshes the local `origin/$WORKFLOW_BASE_BRANCH` ref. We never check out the base branch itself.

### 5. Fast-forward LOCAL `refs/heads/<base>` to match `origin/<base>`

The same trick used inside `base-push`'s `merge_into_branch_transient` helper: `git fetch . <src>:<dst>` updates a ref without checkout, and refuses non-fast-forward by default. Keeping local `<base>` in lockstep with `origin/<base>` is what makes `/base-merge down` (which merges from the local ref) see fresh content after a pull instead of whatever the cache last saw.

```bash
if git -C "$WORKFLOW_MAIN_PATH" rev-parse --verify "refs/heads/$WORKFLOW_BASE_BRANCH" >/dev/null 2>&1; then
  if ! git -C "$WORKFLOW_MAIN_PATH" fetch . \
        "refs/remotes/origin/$WORKFLOW_BASE_BRANCH:refs/heads/$WORKFLOW_BASE_BRANCH" 2>/dev/null; then
    echo "Local '$WORKFLOW_BASE_BRANCH' is not fast-forwardable to origin/$WORKFLOW_BASE_BRANCH — manual sync required."
    echo "Likely cause: $WORKFLOW_BASE_BRANCH is checked out in another worktree, or local has commits not on origin."
    echo "Inspect:"
    echo "  git -C $WORKFLOW_MAIN_PATH worktree list"
    echo "  git -C $WORKFLOW_MAIN_PATH log refs/heads/$WORKFLOW_BASE_BRANCH --not refs/remotes/origin/$WORKFLOW_BASE_BRANCH"
    exit 1
  fi
else
  # First-time pull on this machine: create the local branch pointed at origin's tip.
  git -C "$WORKFLOW_MAIN_PATH" branch "$WORKFLOW_BASE_BRANCH" "refs/remotes/origin/$WORKFLOW_BASE_BRANCH"
fi
```

Two reasons this can fail:

- **Local `<base>` is checked out in some worktree** (commonly the main clone itself). Git refuses to update a checked-out branch via `fetch`. User switches that worktree off the base branch and retries.
- **Local `<base>` has diverged from `origin/<base>`** — i.e. commits exist on local that aren't on origin. The workflow's invariant is "nobody commits on `<base>` directly; only `merge_into_branch_transient` advances it (and always pushes)." If divergence appears, it's a sign of direct user action; user resolves it manually before retry.

Don't try to skip / soft-fail — `base-merge down` after this would silently merge stale content into the feature branch. Better to abort here with a clear hint.

### 6. Merge the base into the current branch

```bash
git merge --no-ff "refs/heads/$WORKFLOW_BASE_BRANCH" -m "Merge branch '$WORKFLOW_BASE_BRANCH' into $ORIGINAL_BRANCH"
```

We merge LOCAL `refs/heads/$WORKFLOW_BASE_BRANCH` — not `origin/$WORKFLOW_BASE_BRANCH`. They point at the same commit after step 5, but reading from the local ref makes `/base-pull` and `/base-merge down` use the same source of truth, so the two skills stay conceptually aligned.

If `--ff-only` is set (see flags), use that instead. On "Already up to date" — git exits without creating a commit; report that and continue.

On conflict — stop. The caller's working tree has conflict markers; the user resolves manually (commit, or `git merge --abort`).

### 7. Do NOT auto-push the merge commit

Unless `--auto-push` was passed, the merge commit stays local. The user typically wants to inspect / run gates / re-test before publishing the merged state. If they want it pushed, they can run `git push` or `/base-push` afterward.

### 8. Report

Tell the user:

- Whether a commit was created on the feature branch before the sync (hash + subject)
- The commit range pushed to `origin/$ORIGINAL_BRANCH`
- Whether local `refs/heads/$WORKFLOW_BASE_BRANCH` was advanced by the fast-forward step (commit range, if any)
- The commit range pulled in from `refs/heads/$WORKFLOW_BASE_BRANCH`
- Whether the merge created a new commit, was "already up to date", or stopped on conflict
- That HEAD is still on `$ORIGINAL_BRANCH`

## Flags

| Flag | Default | Effect |
|------|---------|--------|
| `--no-commit` | off | Skip step 2 entirely. Fail if the tree is dirty. |
| `--auto-push` | off | After the merge succeeds, `git push origin "$ORIGINAL_BRANCH"` to publish the merge commit. |
| `--ff-only` | off | Use `git merge --ff-only` instead of `--no-ff`. Refuses the merge unless it's a fast-forward (no merge commit created). |
| `--message <msg>` | `Merge branch '<base>' into <branch>` | Override the merge commit message. |

## Failure Handling

Stop immediately and leave state as-is on:

- **HEAD is on the base branch**: hard stop with a hint.
- **Pre-commit hook fails:** surface output. NO `--amend`. NO `--no-verify`.
- **Push of feature branch fails:** stop before the fetch.
- **Fetch fails:** stop.
- **Local `<base>` not fast-forwardable to origin/`<base>`** (step 5): stop with the diagnostic hint. Don't fall back to merging from `origin/<base>` — that would mask the divergence and leave local `<base>` stale, breaking later `/base-merge down`.
- **Merge conflict:** stop. The caller's working tree has the conflict markers; surface the conflicted paths. User resolves + commits, or `git merge --abort`.

## What This Skill Will NOT Do

- Check out the base branch anywhere (the entire point of the worktree-era design).
- Push the merge commit back to `origin/<feature>` by default — pass `--auto-push` for that.
- Amend existing commits.
- Use `--no-verify` or `--no-gpg-sign`.
- Force-push anything.
- Attempt to resolve merge conflicts automatically.

## Companion Skills

- **`base-push`** — the reverse: merge the current feature branch INTO the base branch.
- **`base-merge`** — local-only sync (no fetch, no push). Use when you want refs aligned without publishing.
- **`base-pr`** — review pending changes against the base branch in a dedicated sandbox.
