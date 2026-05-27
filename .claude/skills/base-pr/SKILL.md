---
name: base-pr
description: PR-style review of what's new on the base branch since the last review, in a dedicated sandbox worktree. Snapshot the diff, run project gates, then optionally promote the reviewed state to the base via the transient-worktree helper. Base branch is configurable via `.claude/workflow.config` (default `main`).
---

# base-pr — review then promote

PR-style review of **what's new on the base branch since the last review**, in a dedicated sandbox worktree (default name: `<base>-review`). After review, optionally promote the reviewed state to the base via the same `merge_into_branch_transient` helper from `base-push`.

## When to Use

- Before a big release / cut, to take a deliberate look at what's accumulated on the base branch.
- After a series of feature merges land on the base, to audit them as a group.

## Preconditions

- A sandbox worktree exists at `<base>-review` (or pass `--sandbox <name>` to override).
- The sandbox branch has been pushed to origin at least once (the helper requires `origin/<sandbox>` to exist).
- `.claude/workflow.config` exists.

## Execution Steps

### 0. Load workflow config

```bash
source "$(git rev-parse --show-toplevel)/.claude/scripts/_config.sh"
SANDBOX="${SANDBOX:-${WORKFLOW_BASE_BRANCH}-review}"
```

### 1. Capture caller state

```bash
ORIGINAL_BRANCH=$(git rev-parse --abbrev-ref HEAD)
```

The caller's worktree HEAD is never touched. All work happens in the sandbox worktree.

### 2. Refresh and snapshot

```bash
git -C "$WORKFLOW_MAIN_PATH" fetch origin "$WORKFLOW_BASE_BRANCH" "$SANDBOX" --quiet
```

In the sandbox worktree:
- Reset the sandbox branch to `origin/$WORKFLOW_BASE_BRANCH` (this is the "what's pending review" snapshot).
- Compare against the previous review snapshot to enumerate new commits since last review.

### 3. Run gates

> **Configure your project's gates here.** This template doesn't ship gate commands; they're project-specific. Edit this section in your project's copy of the skill to list:
>
> - Lint commands
> - Type-checks
> - Unit / integration tests
> - Any drift checks (codegen artifacts, migration ordering, etc.)
> - Build commands
>
> Run them in the sandbox worktree and surface failures before considering promotion.

### 4. Report review findings

Tell the user:
- What new commits are on the base since the last review
- Which gates passed / failed in the sandbox
- Whether the state is promotable

### 5. (Optional) Promote

If the user says "promote" / "ship" after review, push the sandbox to origin and use the helper:

```bash
git -C "$WORKFLOW_MAIN_PATH/$SANDBOX-worktree" push origin "$SANDBOX"
merge_into_branch_transient "$WORKFLOW_BASE_BRANCH" "origin/$SANDBOX" \
  "Merge branch '$SANDBOX' into $WORKFLOW_BASE_BRANCH"
```

(The helper definition lives in `base-push/SKILL.md`.)

After a successful promotion, re-anchor the sandbox branch to the new `origin/$WORKFLOW_BASE_BRANCH` for the next review cycle.

## Flags

| Flag | Default | Effect |
|------|---------|--------|
| `--sandbox <name>` | `<base>-review` | Override the sandbox worktree/branch name. |
| `--main-path <path>` | `$WORKFLOW_MAIN_PATH` from config (or git toplevel) | Helper's anchor for the transient-worktree promotion. |
| `--no-promote` | off | Just review + report; skip promotion entirely. |

## What This Skill Will NOT Do

- Check out the base branch directly in any persistent worktree.
- Push without explicit promotion (review is read-only by default).
- Auto-resolve merge conflicts on promotion — the helper bails with the transient-worktree path.

## Companion Skills

- **`base-push`** — defines the `merge_into_branch_transient` helper this skill uses for promotion.
- **`base-pull`** — for keeping a feature branch synced with the base; complementary to this skill.
