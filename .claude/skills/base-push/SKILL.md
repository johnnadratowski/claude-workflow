---
name: base-push
description: Advance the shared base branch with the current worktree's branch — without checking the base out in the caller's working directory. Pushes the feature to origin first, then merges into LOCAL base, then pushes local base to origin so local and remote stay in lockstep. Base branch is configurable via `.claude/workflow.config` (default `main`).
---

# base-push — push current branch + advance base branch

Advance the shared base branch (default `main`) with the current worktree's branch — without ever checking the base branch out in the caller's working directory.

Performs, in order:

1. Capture caller state; refuse if HEAD is on the base branch
2. Commit any pending work on the current branch
3. Push the current branch to `origin` (durable backup before any merge)
4. Merge that branch into the LOCAL base branch via the transient-worktree helper, then push the local base to `origin` — so local and remote stay in lockstep
5. Report — the caller's worktree HEAD is unchanged throughout

## When to Use

Invoked when the user says things like:

- "push to base"
- "merge into base"
- "promote to base"
- "ship to base"

## Preconditions

- Caller is in a feature worktree (not on the base branch)
- The feature branch tracks `origin` (or can be pushed there)
- `.claude/workflow.config` exists (or the default base = `main` is acceptable)
- The base branch is NOT currently checked out in any other worktree (the helper checks it out into a transient worktree)
- Network reachable

## The transient-worktree merge helper

This is the canonical mechanism for advancing the base branch (or any shared branch). It's defined here; `base-merge` and `base-pr` reference it.

```bash
# merge_into_branch_transient TARGET_BRANCH SOURCE_REF MERGE_MSG
#
# Advances TARGET_BRANCH by:
#   1. Fast-forwarding local refs/heads/TARGET_BRANCH to origin/TARGET_BRANCH
#      (creating the local branch if it doesn't exist).
#   2. Checking it out — NOT detached — in a short-lived transient worktree.
#   3. Merging SOURCE_REF (always a remote ref like origin/<branch>) into it.
#   4. Pushing local TARGET_BRANCH to origin/TARGET_BRANCH.
# So local and remote refs both advance together; we never bypass local.
# TARGET_BRANCH must NOT be currently checked out in another worktree.
#
# Return codes:
#   0 — success, worktree cleaned up; local TARGET advanced
#   1 — fetch, ref-sync, or worktree-add failure
#   2 — local TARGET has diverged from origin/TARGET; refusing to advance
#   3 — merge conflict (transient worktree preserved at printed path)
#   4 — push rejected — origin/TARGET advanced concurrently (transient preserved)
merge_into_branch_transient() {
  local TARGET="$1"
  local SOURCE_REF="$2"
  local MSG="$3"
  local MAIN_PATH="${WORKFLOW_MAIN_PATH:-$(git rev-parse --show-toplevel)}"
  local TMP_PARENT TMP_WT
  TMP_PARENT="$(mktemp -d -t claude-workflow-merge-XXXX)"
  TMP_WT="$TMP_PARENT/wt"

  # 1. Refresh the local cache of origin/TARGET.
  git -C "$MAIN_PATH" fetch origin "$TARGET" --quiet || return 1

  # 2. Reconcile local refs/heads/TARGET with origin/TARGET before merging.
  # Local TARGET should always be a fast-forward of origin/TARGET (we never
  # commit on TARGET directly; only via this helper, which always pushes).
  # `git fetch . src:dst` is ff-only by default — refuses non-ff updates.
  if git -C "$MAIN_PATH" rev-parse --verify "refs/heads/$TARGET" >/dev/null 2>&1; then
    if ! git -C "$MAIN_PATH" fetch . "refs/remotes/origin/$TARGET:refs/heads/$TARGET" 2>/dev/null; then
      echo "Local '$TARGET' is not fast-forwardable to origin/$TARGET — manual sync required."
      echo "Inspect with: git -C $MAIN_PATH log refs/heads/$TARGET --not refs/remotes/origin/$TARGET"
      rm -rf "$TMP_PARENT"
      return 2
    fi
  else
    git -C "$MAIN_PATH" branch "$TARGET" "refs/remotes/origin/$TARGET" || { rm -rf "$TMP_PARENT"; return 1; }
  fi

  # 3. Check out local TARGET (NOT detached) in the transient worktree.
  # Committing on a branch-attached worktree advances the local ref, which
  # is exactly what we want — local TARGET should never lag origin/TARGET.
  if ! git -C "$MAIN_PATH" worktree add "$TMP_WT" "$TARGET" 2>&1; then
    echo "Worktree add failed — is '$TARGET' already checked out somewhere?"
    git -C "$MAIN_PATH" worktree list >&2
    rm -rf "$TMP_PARENT"
    return 1
  fi

  # 4. Merge source. Local TARGET ref moves with the new commit because
  # the worktree is attached to refs/heads/TARGET (not detached).
  if ! git -C "$TMP_WT" merge --no-ff "$SOURCE_REF" -m "$MSG"; then
    echo "Merge conflict in transient worktree at: $TMP_WT"
    echo "Resolve, commit, then:"
    echo "  git -C $TMP_WT push origin $TARGET && git -C $MAIN_PATH worktree remove $TMP_WT"
    return 3
  fi

  # 5. Push local TARGET to origin. Local refs/heads/TARGET is already at
  # the merge commit; this just publishes it.
  if ! git -C "$TMP_WT" push origin "$TARGET"; then
    echo "Push rejected — origin/$TARGET advanced between fetch and push."
    echo "Transient worktree preserved at: $TMP_WT"
    echo "Diagnose, retry 'git -C $TMP_WT push origin $TARGET', then 'git -C $MAIN_PATH worktree remove $TMP_WT'."
    return 4
  fi

  # 6. Worktree removal does NOT roll back the branch ref — local TARGET
  # stays at the merge commit (now matches origin/TARGET).
  git -C "$MAIN_PATH" worktree remove "$TMP_WT"
  rm -rf "$TMP_PARENT"
  return 0
}
```

Five design decisions baked into the helper:

- **`SOURCE_REF` is always `origin/<branch>`, never a local ref.** Every caller pushes its feature/sandbox branch to `origin` BEFORE invoking this helper, so the merge in the transient worktree depends only on durable remote state. If a caller's push fails, we stop before any merge ever begins.
- **Local `refs/heads/<target>` is advanced FIRST, then pushed — never bypassed.** The helper uses a branch-attached transient worktree (no `--detach`), so the merge commit lands on `refs/heads/<target>` directly; the push only publishes the already-updated local ref. A detached design would advance `origin/<target>` while leaving the local ref stale — causing drift.
- **Local `<target>` must not be ahead of `origin/<target>`** (return code 2). We never commit on `<target>` outside this helper, so the only way it drifts ahead is via direct user action; if that happens, the user resolves it manually before re-running.
- **`--no-ff` is mandatory.** Preserves merge topology.
- **Conflicts and push rejections leave the transient worktree intact** at a printed path. The caller's worktree HEAD is never touched, so the failure mode is "extra directory on disk that the user resolves manually" — not "user's working tree is mid-conflict."

> **Precondition:** `<target>` is not currently checked out in any other worktree. The whole point of the worktree-era design is that the base branch lives only as a ref and only ever materializes in a transient worktree during these helper invocations.

## Execution Steps

### 0. Load workflow config

```bash
source "$(git rev-parse --show-toplevel)/.claude/scripts/_config.sh"
```

### 1. Capture state and refuse the wrong starting branch

```bash
ORIGINAL_BRANCH=$(git rev-parse --abbrev-ref HEAD)
```

Refuse if `ORIGINAL_BRANCH` equals `$WORKFLOW_BASE_BRANCH`. Hint: there's nothing to merge in.

### 2. Commit any pending work

Standard commit flow:

- `git status` + `git diff` to review what's pending
- `git log --oneline -5` to match the repo's commit-message style
- Craft a conventional-commits message that reflects the `why`, not a file list
- Stage only the relevant files (no `git add -A` / `git add .`)
- HEREDOC for the `-m` argument so formatting is preserved
- Never `--amend`, never `--no-verify`

**Skip this step when:** `git status` is clean AND `git log origin/$ORIGINAL_BRANCH..HEAD` is empty (nothing new to commit OR push). Note the skip and proceed.

If the tree is clean but there are unpushed commits, skip the commit and go straight to push.

### 3. Push the feature branch to `origin` (backup before the merge)

```bash
git push origin "$ORIGINAL_BRANCH"
```

Abort the whole skill on failure. The feature branch must be on `origin` so the helper can merge `origin/$ORIGINAL_BRANCH` safely.

### 4. Merge into the base branch via the transient worktree

```bash
merge_into_branch_transient "$WORKFLOW_BASE_BRANCH" "origin/$ORIGINAL_BRANCH" \
  "Merge branch '$ORIGINAL_BRANCH' into $WORKFLOW_BASE_BRANCH"
```

Route by return code:

- **0**: continue to report.
- **1**: surface the fetch / worktree-add error and stop.
- **2 (local diverged)**: stop. Local `refs/heads/$WORKFLOW_BASE_BRANCH` has commits not on origin. Inspect: `git log refs/heads/$WORKFLOW_BASE_BRANCH --not origin/$WORKFLOW_BASE_BRANCH`.
- **3 (conflict)**: stop. The user resolves in the transient worktree at the printed path. The caller's working tree is intact.
- **4 (push rejected)**: stop. The merge commit is preserved in the transient worktree's local base ref. User diagnoses (likely a concurrent push) and retries `git -C <tmp> push origin <base>` manually.

### 5. Report

Tell the user:

- Whether a commit was created on the feature branch (hash + subject)
- The commit range pushed to `origin/$ORIGINAL_BRANCH`
- The merge commit hash on the base branch (look it up: `git -C $WORKFLOW_MAIN_PATH rev-parse refs/heads/$WORKFLOW_BASE_BRANCH`)
- That HEAD on the caller's worktree is unchanged (`$ORIGINAL_BRANCH`)
- That local and `origin/$WORKFLOW_BASE_BRANCH` are now at the same commit
- The transient worktree was created and cleaned up automatically

If the helper returned 3 or 4, the report instead surfaces the transient-worktree path and the exact commands to recover.

## Flags

| Flag | Default | Effect |
|------|---------|--------|
| `--main-path <path>` | `$WORKFLOW_MAIN_PATH` from config (or git toplevel) | Path to the main clone (anchors the helper). |
| `--no-commit` | off | Skip step 2 entirely. Fail if the tree is dirty. |
| `--message <msg>` | `Merge branch '<branch>' into <base>` | Override the merge commit message. |

## Failure Handling

Stop immediately and leave state as-is on:

- **HEAD is on the base branch**: hard stop with the right-skill hint.
- **Pre-commit hook fails:** surface output. NO `--amend`. NO `--no-verify`. User fixes the underlying issue and re-runs (a fresh commit, not an amend).
- **Push of feature branch fails:** stop. The base branch was never touched.
- **Helper returns 2 (diverged):** stop. User resolves the local-base divergence manually.
- **Helper returns 3 (conflict):** stop. Print the transient-worktree path. Caller's tree is intact.
- **Helper returns 4 (push rejected):** stop. Same: transient-worktree path printed, caller's tree intact.

## What This Skill Will NOT Do

- Check out the base branch in the caller's working directory (the entire reason for the transient-worktree mechanism).
- Amend existing commits.
- Use `--no-verify`, `--no-gpg-sign`, or any hook-bypass flag.
- Force-push anything.
- Attempt to auto-resolve merge conflicts.

## Companion Skills

- **`base-pull`** — the reverse: merge `origin/<base>` INTO the current feature branch.
- **`base-merge`** — local-only sync (no fetch, no push). Same transient-worktree pattern minus the publish step.
- **`base-pr`** — review pending changes on `origin/<base>` in a dedicated sandbox; uses the same transient-worktree helper for its promotion step.
