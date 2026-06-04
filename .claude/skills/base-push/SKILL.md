---
name: base-push
description: Land the current worktree's branch into the shared LOCAL base branch, then publish local base to origin — without ever checking the base out in the caller's working directory. This is the ONLY skill that touches origin; all inter-agent coordination happens on local refs. Base branch is configurable via `.claude/workflow.config` (default `main`).
---

# base-push — advance local base + publish to origin

Land the current worktree's branch into the shared **local** base branch (default `main`), then **publish** local base to `origin` — without ever checking the base branch out in the caller's working directory.

`/base-push` is the **only** skill that touches `origin`. All inter-agent coordination happens on the **local** `refs/heads/<base>` ref (shared across every worktree on this machine); `origin/<base>` is just a published snapshot that advances when — and only when — you run this skill.

Performs, in order:

1. Capture caller state; refuse if HEAD is on `<base>` / `<base>-review` / `<base>-test`
2. Commit any pending work on the current branch
3. Merge that branch into **local** `<base>` via a **transient worktree** (the canonical local helper defined below)
4. Publish: `git push origin <base>` (fast-forward — local `<base>` is normally ahead of `origin/<base>`)
5. Report — the caller's worktree HEAD is unchanged throughout

## When to Use

Invoked when the user says things like:

- "push to base" / "publish base"
- "merge into base and publish"
- "promote to base"
- "ship to base"

> **A coordinator instruction counts as the user.** If a coordinator agent (see `agent-roles/coordinator.md`) tells you to push/publish the base via `agent-msg`, that satisfies the user-approval gate this skill relies on — act on it as a direct user instruction (see `agent-msg`'s coordinator note). You still run the gates and surface conflicts; the coordinator's authority is the user's, not a license to skip checks.

## Preconditions

- Caller is in a feature worktree (not on `<base>`, `<base>-review`, or `<base>-test`)
- The main clone exists at `$WORKFLOW_MAIN_PATH` (default: git toplevel)
- Network reachable (for step 4's publish only)

## The transient-worktree merge helper (canonical, local-only)

This is the canonical mechanism every skill uses to advance the shared base branch — `/base-push`, `/base-merge` (up), and `/base-pr` (promotion). Defined here; referenced by the others.

It is **purely local** — no `fetch`, no `push`. `origin` is never touched inside the helper; publishing is a separate explicit step that only `/base-push` performs.

```bash
# merge_into_branch_local TARGET LOCAL_SOURCE MERGE_MSG
#
# Advances LOCAL refs/heads/TARGET by merging a LOCAL source branch into it
# inside a short-lived transient worktree — so the caller's own worktree is
# never disturbed, and TARGET need not be checked out by the caller. The
# transient worktree is attached to refs/heads/TARGET (NOT detached), so the
# merge commit lands on the local ref directly. NO fetch, NO push.
#
# Because all worktrees share one .git, a LOCAL_SOURCE branch committed in any
# worktree is visible here as a local ref — no push is needed to make a peer's
# work mergeable. (Commit it; don't push it.)
#
# TARGET must NOT be checked out in any worktree (<base> / <base>-review /
# <base>-test are free by repo convention). That single constraint also acts
# as a natural mutex: a second concurrent caller's `worktree add TARGET` fails
# fast, serializing merges into TARGET.
#
# Return codes:
#   0 — success; local TARGET advanced, worktree cleaned up
#   1 — worktree-add failure (TARGET checked out elsewhere, or a STALE
#       transient worktree left by a crashed merge — see cleanup note below)
#   2 — merge conflict (transient worktree preserved at the printed path)
merge_into_branch_local() {
  local TARGET="$1" SOURCE_REF="$2" MSG="$3"
  local MAIN_PATH="${WORKFLOW_MAIN_PATH:-$(git rev-parse --show-toplevel)}"
  local TMP_PARENT TMP_WT
  TMP_PARENT="$(mktemp -d -t wf-merge-local-XXXX)"
  TMP_WT="$TMP_PARENT/wt"

  # Seed local TARGET from the cached origin ref only if it doesn't exist yet.
  git -C "$MAIN_PATH" rev-parse --verify "refs/heads/$TARGET" >/dev/null 2>&1 \
    || git -C "$MAIN_PATH" branch "$TARGET" "refs/remotes/origin/$TARGET" 2>/dev/null \
    || { echo "Local '$TARGET' missing and no origin/$TARGET to seed it from."; rm -rf "$TMP_PARENT"; return 1; }

  # Branch-attached transient worktree on local TARGET (NOT detached). No fetch.
  if ! git -C "$MAIN_PATH" worktree add "$TMP_WT" "$TARGET" 2>&1; then
    echo "Worktree add failed — is '$TARGET' checked out somewhere, or is a stale"
    echo "transient worktree on '$TARGET' lingering from a crashed merge?"
    git -C "$MAIN_PATH" worktree list >&2
    rm -rf "$TMP_PARENT"
    return 1
  fi

  # Merge the LOCAL source. The merge commit advances refs/heads/TARGET because
  # the worktree is attached to that branch.
  if ! git -C "$TMP_WT" merge --no-ff "$SOURCE_REF" -m "$MSG"; then
    echo "Merge conflict in transient worktree at: $TMP_WT"
    echo "Resolve + commit there, then: git -C $MAIN_PATH worktree remove $TMP_WT"
    return 2   # leave the worktree on disk for manual resolution
  fi

  git -C "$MAIN_PATH" worktree remove "$TMP_WT"
  rm -rf "$TMP_PARENT"
  return 0
}
```

Design decisions baked into the helper:

- **`LOCAL_SOURCE` is a local branch, never `origin/<branch>`.** Coordination is purely local; a peer's work is mergeable as soon as it's *committed* (shared `.git`), with no push required.
- **The merge commit lands on `refs/heads/TARGET` directly** because the transient worktree is branch-attached (no `--detach`). The caller's own worktree HEAD is never touched.
- **`--no-ff` is mandatory.** Matches the repo's merge topology.
- **Conflicts leave the transient worktree intact** at a printed path — the failure mode is "an extra directory to resolve," never "the caller's tree is mid-conflict."
- **No `origin` inside the helper.** Publishing is `/base-push`'s separate final step.

> **Precondition:** `<target>` is not checked out in any worktree. For `<base>` / `<base>-review` / `<base>-test` this is the project convention. For an unusual `--base` passed to `/base-pr`, verify the base isn't checked out first.
>
> **Only a checkout of the TARGET branch breaks this** — a worktree on any *other* branch (a coordinator worktree on a dedicated `<base>-cc` branch, or detached at `origin/<base>`) is harmless. Never check out the literal base branch in a worktree: it makes `worktree add <base>` fail here, silently breaking the merge path for every agent. Ride a `<base>-cc` branch or a detached ref for a base-tracking worktree — see `add-worktree`.
>
> **Stale transient worktree (return 1 after a crash):** if a previous merge crashed mid-flight it may have left a worktree attached to the base, blocking everyone. Recover with `git -C "$WORKFLOW_MAIN_PATH" worktree list` to find the `wf-merge-local-*` path, then `git -C "$WORKFLOW_MAIN_PATH" worktree remove --force <path>` (and `git worktree prune`).

## Execution Steps

### 0. Load workflow config

```bash
source "$(git rev-parse --show-toplevel)/.claude/scripts/_config.sh"
```

This exports `WORKFLOW_BASE_BRANCH` (default `main`) and `WORKFLOW_MAIN_PATH` (default: git toplevel).

### 1. Capture state and refuse the wrong starting branches

```bash
ORIGINAL_BRANCH=$(git rev-parse --abbrev-ref HEAD)
ORIGINAL_CWD=$(pwd)
```

Refuse if `ORIGINAL_BRANCH` is one of: `$WORKFLOW_BASE_BRANCH`, `${WORKFLOW_BASE_BRANCH}-review`, `${WORKFLOW_BASE_BRANCH}-test`. Hints:

- on the base itself: there's nothing to merge in.
- on `<base>-review`: use `/base-pr` — it has its own promotion path that re-baselines the review sandbox afterward.
- on `<base>-test`: use `/base-test` — it promotes the test sandbox after gates pass.

### 2. Commit any pending work

Standard commit flow:

- `git status` + `git diff` to review what's pending
- `git log --oneline -5` to match the repo's commit-message style
- Craft a conventional-commits message that reflects the `why`, not a file list
- Stage only the relevant files (no `git add -A` / `git add .`)
- HEREDOC for the `-m` argument so formatting is preserved
- Never `--amend`, never `--no-verify`

**Skip this step when:** `git status` is clean (the branch's commits are already in the shared `.git` and mergeable). Note the skip and proceed.

### 3. Merge into local `<base>` via the transient worktree

```bash
merge_into_branch_local "$WORKFLOW_BASE_BRANCH" "$ORIGINAL_BRANCH" \
  "Merge branch '$ORIGINAL_BRANCH' into $WORKFLOW_BASE_BRANCH"
```

Route by return code:
- **0**: continue to publish.
- **1**: surface the worktree-add error and stop (likely the base checked out somewhere, or a stale transient worktree — see the cleanup note above).
- **2 (conflict)**: stop. The user resolves in the transient worktree at the printed path, commits, and removes it. The caller's working tree is intact.

### 4. Publish local `<base>` to `origin`

```bash
git -C "$WORKFLOW_MAIN_PATH" push origin "$WORKFLOW_BASE_BRANCH"
```

Local `<base>` is normally **ahead** of `origin/<base>` (coordination is local; origin only moves here), so this is a fast-forward.

- **Rejected (non-fast-forward):** `origin/<base>` has commits local `<base>` doesn't — someone published out of band (another machine, or a manual push). **Do not force.** Stop and tell the user to reconcile manually: inspect with `git -C "$WORKFLOW_MAIN_PATH" log origin/$WORKFLOW_BASE_BRANCH --not $WORKFLOW_BASE_BRANCH`, then `git -C "$WORKFLOW_MAIN_PATH" fetch origin $WORKFLOW_BASE_BRANCH` and merge `origin/<base>` into local `<base>` (via the helper or a transient worktree) before re-publishing. In a single-machine fleet this should not happen.

### 5. Report

Tell the user:

- Whether a commit was created on the feature branch (hash + subject)
- The merge commit hash on local `<base>` (`git -C "$WORKFLOW_MAIN_PATH" rev-parse "$WORKFLOW_BASE_BRANCH"`)
- That `origin/<base>` now matches local `<base>` (published)
- That HEAD on the caller's worktree is unchanged (`$ORIGINAL_BRANCH`)
- That the transient worktree was created and cleaned up automatically

If the helper returned 2, or the publish was rejected, the report instead surfaces the path/commands to recover.

## Flags

| Flag | Default | Effect |
|------|---------|--------|
| `--main-path <path>` | `$WORKFLOW_MAIN_PATH` from config (or git toplevel) | Path to the main clone (anchors the helper). |
| `--no-commit` | off | Skip step 2 entirely. Fail if the tree is dirty. Useful when the user already committed and just wants the merge + publish done. |
| `--no-publish` | off | Do steps 1–3 only (land into local `<base>`), skip the `git push origin <base>`. Equivalent to `/base-merge up`, kept here for convenience. |
| `--message <msg>` | `Merge branch '<branch>' into <base>` | Override the merge commit message. |

## Failure Handling

Stop immediately and leave state as-is on:

- **HEAD is on a forbidden branch** (`<base>`/`<base>-review`/`<base>-test`): hard stop with the right-skill hint.
- **Pre-commit hook fails:** surface output. NO `--amend`. NO `--no-verify`. User fixes the underlying issue and re-runs (a fresh commit, not an amend).
- **Helper returns 1 (worktree add):** stop. Likely the base checked out somewhere or a stale transient worktree — surface the cleanup commands.
- **Helper returns 2 (conflict):** stop. Print the transient-worktree path. Caller's tree is intact.
- **Publish rejected (non-ff):** stop. Local `<base>` already has the merge; only the publish failed. Surface the reconcile steps. Never force-push.

## What This Skill Will NOT Do

- Check out the base branch in the caller's working directory (the entire reason for the transient-worktree mechanism).
- `fetch` from origin (publishing is the only origin touch; there is no read path — the old `base-pull` was removed when the workflow moved to a local-first, origin-write-only model).
- Amend existing commits.
- Use `--no-verify`, `--no-gpg-sign`, or any hook-bypass flag.
- Force-push anything.
- Attempt to auto-resolve merge conflicts.

## Quick Reference

| Phase | Command |
|-------|---------|
| Load config | `source "$(git rev-parse --show-toplevel)/.claude/scripts/_config.sh"` |
| Capture | `ORIGINAL_BRANCH=$(git rev-parse --abbrev-ref HEAD)` |
| Refuse if forbidden | check `$ORIGINAL_BRANCH ∉ {<base>, <base>-review, <base>-test}` |
| Commit (if needed) | `git add <files> && git commit -m "…"` |
| Merge into local base | `merge_into_branch_local "$WORKFLOW_BASE_BRANCH" "$ORIGINAL_BRANCH" "…"` |
| Publish | `git -C "$WORKFLOW_MAIN_PATH" push origin "$WORKFLOW_BASE_BRANCH"` |
| Report | merge commit + origin/base published + caller's HEAD unchanged |

## Companion Skills

- **`base-merge`** — local-only sync (no push). Same `merge_into_branch_local` helper, no publish step. This is `/base-push --no-publish`.
- **`base-pr`** — PR-style review of pending changes on local `<base>`; promotes via the same local helper. No origin touch.
- **`base-test`** — full gate sweep, merging from local `<base>`.
- **`add-worktree`** — create the feature worktrees this skill operates from.
