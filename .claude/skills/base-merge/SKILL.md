---
name: base-merge
description: Local-only sync of the configured base branch — no network. Merge the LOCAL `<base>` ref into the current branch (`down`), and/or advance the local base ref to include the current branch's commits via a transient worktree (`up`). Use when you want refs aligned across worktrees without publishing.
---

# base-merge — local-only base-branch sync

Sync the **local** base-branch ref with the caller's current branch — **no network**. No `fetch`, no `push`. Pure local-ref management.

Local `<base>` is the single coordination ref for the whole fleet (every worktree shares one `.git`). `origin/<base>` is only a published snapshot that advances when someone runs `/base-push`; this skill never reads or writes it.

Two directions, both off by default unless you opt in. **Both halves operate on local `refs/heads/<base>`:**

- **down**: merge local `<base>` into the current branch.
- **up**: advance local `<base>` to include the current branch's commits, via the canonical `merge_into_branch_local` helper (defined in `/base-push`) — a transient worktree, no push.

Default invocation does both (down, then up) — that's the "keep them in sync" use case the skill is named for.

**Use this when:**

- You want your local `<base>` ref reflecting in-flight work so other worktrees on the same machine can branch off it / merge it down.
- You're not ready to publish to `origin` yet (that's a separate explicit `/base-push`).

**Do NOT use this when:**

- You actually want to publish to the remote — use `/base-push`.

## Invocation

```
/base-merge              # bidirectional (down then up). Default.
/base-merge down         # merge local <base> into current branch only
/base-merge up           # advance local <base> from current branch only
/base-merge sync         # alias for the default (down then up)
```

## When to Use

Invoked when the user says things like:

- "sync base locally" / "merge base locally"
- "keep local base in sync" / "advance local base"
- "merge down base" (→ `down`)
- "I want local base up to date with this branch"

> **A coordinator instruction counts as the user.** If a coordinator agent (see `agent-roles/coordinator.md`) tells you to sync/advance the local base via `agent-msg`, treat it as a direct user instruction (see `agent-msg`'s coordinator note).

## Preconditions

- Caller is in a feature worktree (HEAD is NOT on `<base>`, `<base>-review`, or `<base>-test`).
- The local `<base>` ref exists (any clone with `origin` set has it; the helper will seed it from `origin/<base>` if missing).
- The current branch's working tree is clean OR the caller has acknowledged uncommitted state — this skill does NOT auto-commit or auto-stash. (Compare to `/base-push`, which has a commit step.)

If the working tree is dirty, surface `git status` and ask whether to abort or continue (the down-merge can produce conflicts that interact badly with uncommitted work).

## Drift note

Because this skill never fetches, local `<base>` is the source of truth and is normally **ahead** of `origin/<base>` — origin only catches up on an explicit `/base-push`. **Every invocation reports drift** at the end (computed from the cached `origin/<base>` ref, no fetch) so unpublished work is never invisible:

```
Local <base> is N commits ahead of origin/<base> (unpublished), M behind.
```

The "ahead" count is the normal state (work assembled locally, not yet published). A non-zero "behind" count is unusual in a single-machine fleet — it means someone published to `origin/<base>` out of band; it's reported for visibility, not treated as an error (origin is a snapshot, not the source of truth).

## Execution Steps

### 0. Load workflow config

```bash
source "$(git rev-parse --show-toplevel)/.claude/scripts/_config.sh"
```

### 1. Capture state and refuse the wrong starting branches

```bash
ORIGINAL_BRANCH=$(git rev-parse --abbrev-ref HEAD)
```

Refuse if `ORIGINAL_BRANCH` is one of: `$WORKFLOW_BASE_BRANCH`, `${WORKFLOW_BASE_BRANCH}-review`, `${WORKFLOW_BASE_BRANCH}-test`. Hints:

- on the base itself: this skill exists to advance the base FROM another branch — can't run with the base checked out. (In the worktree model, the base shouldn't be checked out anywhere — the transient `worktree add <base>` in step "Up" requires it free. A coordinator worktree on a dedicated `<base>-cc` branch or detached at `origin/<base>` is fine; only the literal base branch being checked out breaks this.)
- on `<base>-review`: use `/base-pr`. Its baseline machinery is the right tool for advancing the review sandbox.
- on `<base>-test`: use `/base-test`. It owns the `<base>-test` ↔ `<base>` relationship.

Validate the requested direction:

```bash
DIRECTION="${1:-both}"   # default: both (down then up)
case "$DIRECTION" in
  down|up|both|sync) ;;  # 'sync' is an alias for 'both'
  *) echo "Unknown direction '$DIRECTION'. Use: down | up | both | sync"; exit 1 ;;
esac
[ "$DIRECTION" = "sync" ] && DIRECTION=both
```

### 2. Snapshot the starting refs for the drift report

```bash
LOCAL_BASE_START=$(git -C "$WORKFLOW_MAIN_PATH" rev-parse "$WORKFLOW_BASE_BRANCH")
REMOTE_BASE_CACHED=$(git -C "$WORKFLOW_MAIN_PATH" rev-parse "origin/$WORKFLOW_BASE_BRANCH" 2>/dev/null || echo "")
```

Read-only — no refs modified, no network. The drift line in the final report compares the *end* state against this cached `origin/<base>`.

### 3. Down-merge (if `DIRECTION` is `down` or `both`)

```bash
git merge --no-ff "refs/heads/$WORKFLOW_BASE_BRANCH" -m "Merge branch '$WORKFLOW_BASE_BRANCH' into $ORIGINAL_BRANCH (local sync)"
```

Notes:

- We merge local `<base>` (`refs/heads/<base>`), the fleet's source of truth — never `origin/<base>`. The `refs/heads/` form resolves cleanly even when `<base>` is checked out in another worktree (git allows merging *from* such a branch; it only blocks *checkout* of it).
- On "Already up to date" — git exits without creating a commit. Report and continue.
- On conflict — stop. The caller's working tree has conflict markers; the user resolves manually (`git add`, `git commit`) or `git merge --abort`. **Do not** proceed to the up-merge if down conflicted — local `<base>` shouldn't be advanced from a half-merged state.

### 4. Up-merge (if `DIRECTION` is `up` or `both`)

Use the canonical `merge_into_branch_local` helper (defined in `/base-push`'s SKILL.md) — a transient worktree attached to local `<base>`, merging the local current branch in, with no fetch and no push:

```bash
merge_into_branch_local "$WORKFLOW_BASE_BRANCH" "$ORIGINAL_BRANCH" \
  "Merge branch '$ORIGINAL_BRANCH' into $WORKFLOW_BASE_BRANCH (local sync)"
```

The source ref is the local branch name (`$ORIGINAL_BRANCH`) — there's no remote dependency, by design.

A conflict in the up-merge is unusual when `DIRECTION=both` (we just merged local `<base>` into the current branch in step 3, so the current branch already includes everything on local `<base>`). It's more likely when `DIRECTION=up` alone and local `<base>` has commits the current branch doesn't.

Route by return code (see the helper): **0** continue; **1** worktree-add failure (base checked out somewhere, or a stale transient worktree — surface cleanup); **2** conflict, tmp worktree retained at the printed path for manual resolution. Do NOT advance local `<base>` from a half-merged state.

### 5. Report

```bash
LOCAL_BASE_END=$(git -C "$WORKFLOW_MAIN_PATH" rev-parse "$WORKFLOW_BASE_BRANCH")
if [ -n "$REMOTE_BASE_CACHED" ]; then
  AHEAD=$(git -C "$WORKFLOW_MAIN_PATH" rev-list --count "${REMOTE_BASE_CACHED}..${LOCAL_BASE_END}")
  BEHIND=$(git -C "$WORKFLOW_MAIN_PATH" rev-list --count "${LOCAL_BASE_END}..${REMOTE_BASE_CACHED}")
else
  AHEAD="?"; BEHIND="?"
fi
```

Tell the user:

- **Direction taken**: `down`, `up`, or `both`.
- **Down result** (if run): merge commit hash + subject, or "Already up to date", or "Stopped on conflict — resolve manually."
- **Up result** (if run): the new local `<base>` SHA (and how many commits it advanced by), or "Already up to date", or "Stopped on conflict — see <tmp-path>."
- **Drift line**:
  ```
  Local <base>: <LOCAL_BASE_END>
  Cached origin/<base>: <REMOTE_BASE_CACHED>
  Local <base> is <AHEAD> commits ahead of origin/<base> (unpublished), <BEHIND> behind.
  ```
- **Reminder** if `AHEAD > 0`: `Local <base> has unpublished commits. /base-push to publish.`
- **Note** if `BEHIND > 0`: `origin/<base> has commits not in local <base> — someone published out of band. Reconcile manually if intended (git fetch origin <base>, then merge origin/<base> into local <base>).`
- That HEAD is still on `$ORIGINAL_BRANCH`.

## Flags

| Flag             | Default | Effect                                                                              |
| ---------------- | ------- | ----------------------------------------------------------------------------------- |
| `--message <m>`  | auto    | Override the merge commit message (applied to whichever direction's merge actually creates a commit). |

## Failure Handling

Stop immediately and leave state as-is on:

- **HEAD on a forbidden branch** (`<base>` / `<base>-review` / `<base>-test`): hard stop with the right-skill hint.
- **Down-merge conflict**: stop in the caller's working tree, surface conflicted paths. Do NOT proceed to the up-merge.
- **Up-merge helper return 1** (`git worktree add` fails — base checked out elsewhere, or a stale transient worktree): surface the conflict + cleanup commands, do not proceed.
- **Up-merge helper return 2** (conflict in the tmp worktree): stop, print the tmp path, leave it on disk for manual resolution.

## What This Skill Will NOT Do

- Fetch from or push to `origin`. Publishing is `/base-push`'s job; there is no pull path (the workflow is local-first, origin write-only).
- Commit pending work on the current branch. That's `/base-push`'s job. This skill is for users who have already committed (or who are working clean) and just want refs aligned.
- Check out the base in the caller's worktree (or anywhere persistent).
- Force-push, `--amend`, `--no-verify`, or `--no-gpg-sign`.
- Resolve merge conflicts automatically.

## Quick Reference

| Phase              | Command                                                                                         |
| ------------------ | ----------------------------------------------------------------------------------------------- |
| Capture            | `ORIGINAL_BRANCH=$(git rev-parse --abbrev-ref HEAD)`                                            |
| Refuse if forbidden| `$ORIGINAL_BRANCH ∉ {<base>, <base>-review, <base>-test}`                                       |
| Down               | `git merge --no-ff "refs/heads/$WORKFLOW_BASE_BRANCH" -m "…"`                                   |
| Up (no push!)      | `merge_into_branch_local "$WORKFLOW_BASE_BRANCH" "$ORIGINAL_BRANCH" "…"`                        |
| Drift line         | `git rev-list --count origin/<base>..<base>` (ahead) + `<base>..origin/<base>` (behind)         |

## Companion Skills

- **`base-push`** — advance local `<base>` AND publish to `origin`. The only skill that touches origin. Defines `merge_into_branch_local`.
- **`base-pr`** — PR-style review of pending changes on local `<base>`, in the `<base>-review` sandbox.
- **`base-test`** — full gate sweep against `<base>-test`.

## Difference vs. `base-push`

| Skill        | Fetches? | Pushes? | Touches local `<base>`? | Touches current branch? |
| ------------ | -------- | ------- | ----------------------- | ----------------------- |
| `base-push`  | no       | **yes** (publishes local `<base>` to origin) | yes (advances via `merge_into_branch_local`, then publishes) | yes (commits if dirty)  |
| `base-merge` | **no**   | **no**  | yes (advances via the same local helper; both halves source from local `<base>`) | yes (down-merge into it) |
