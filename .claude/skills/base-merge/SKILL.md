---
name: base-merge
description: Local-only sync of the configured base branch — no network. Either merge the locally-cached `origin/<base>` into the current branch (`down`), or advance the local base ref to include the current branch's commits via a transient worktree (`up`). Use when you want refs aligned without publishing.
---

# base-merge — local-only base-branch sync

Sync the **local** base-branch ref with the caller's current branch — **no network**. No `fetch`, no `push`. Pure local-ref management.

Two modes:

- **down**: merge the locally-cached `origin/$WORKFLOW_BASE_BRANCH` into the current branch.
- **up**: advance the local `$WORKFLOW_BASE_BRANCH` ref to include the current branch's commits, via a transient worktree (the `merge_into_branch_transient` helper from `base-push`, with the push step removed).

## When to Use

- You want your local base-branch ref reflecting in-flight work so other worktrees on the same machine can branch off it.
- You're experimenting and not ready to advance `origin/<base>` yet.

## When NOT to Use

- You actually want the latest published `origin/<base>` — use `base-pull` (which fetches first).
- You want to publish — use `base-push`.

## Usage

```bash
/base-merge              # default: both directions (down then up)
/base-merge down         # merge origin/<base> (locally-cached) into current branch only
/base-merge up           # advance local <base> from current branch only
```

## Caveats — staleness

Because this skill never fetches, the "latest `origin/<base>`" it merges down is whatever your local cache last saw — possibly hours or days stale. Because it never pushes, your local `<base>` will silently diverge from `origin/<base>`.

The skill **refuses the up-merge** when local `<base>` is behind `origin/<base>` (cached) unless `--allow-stale` is passed.

## Execution Steps

### 0. Load workflow config

```bash
source "$(git rev-parse --show-toplevel)/.claude/scripts/_config.sh"
```

### 1. Capture state and refuse the wrong starting branch

```bash
ORIGINAL_BRANCH=$(git rev-parse --abbrev-ref HEAD)
```

Refuse if `ORIGINAL_BRANCH` equals `$WORKFLOW_BASE_BRANCH`.

### 2. Snapshot the local refs (read-only)

```bash
LOCAL_BASE=$(git -C "$WORKFLOW_MAIN_PATH" rev-parse "refs/heads/$WORKFLOW_BASE_BRANCH" 2>/dev/null || echo "")
REMOTE_BASE_CACHED=$(git -C "$WORKFLOW_MAIN_PATH" rev-parse "refs/remotes/origin/$WORKFLOW_BASE_BRANCH" 2>/dev/null || echo "")
```

These are read-only — no refs are modified yet. The drift line in the final report compares the *end* state against `origin/<base>` (still the cached value, since we never fetched).

### 3. Down (if requested)

```bash
git merge --no-ff "origin/$WORKFLOW_BASE_BRANCH" -m "Merge branch '$WORKFLOW_BASE_BRANCH' into $ORIGINAL_BRANCH (local sync)"
```

Two important details:

- We merge `origin/$WORKFLOW_BASE_BRANCH` (the locally-cached remote ref), not local `$WORKFLOW_BASE_BRANCH`. Reason: `origin/<base>` is the "last known good" published state; local `<base>` may have unpublished commits already.
- On conflict — stop. The caller's working tree has conflict markers; the user resolves manually (`git add`, `git commit`) or `git merge --abort`. **Do not** proceed to the up-merge if down conflicted — local `<base>` shouldn't be advanced from a half-merged state.

### 4. Up (if requested)

Use the canonical `merge_into_branch_transient` helper from `base-push`, but skip its final push step. Same FF-update-then-merge-then-push design, just without the publish.

Refuse if local `$WORKFLOW_BASE_BRANCH` is behind the cached `origin/$WORKFLOW_BASE_BRANCH` and `--allow-stale` wasn't passed.

### 5. Report

Show: which direction(s) ran, any commits added, the resulting `git rev-list --left-right --count origin/$WORKFLOW_BASE_BRANCH...refs/heads/$WORKFLOW_BASE_BRANCH` drift counts.

## Flags

| Flag | Default | Effect |
|------|---------|--------|
| `--allow-stale` | off | Permit the up-merge even when local base is behind the cached origin base. |
| `--message <msg>` | default | Override the merge commit message. |

## Companion Skills

- **`base-pull`** — fetches first; what you want most of the time.
- **`base-push`** — fetches + advances origin too.
