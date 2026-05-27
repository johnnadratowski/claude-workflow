---
name: remove-worktree
description: Tear down a git worktree created by `/add-worktree`. Confirms before removing (unless `--force`). Removes the directory via `git worktree remove`. Does NOT delete the branch — that's separate.
---

# remove-worktree

```bash
/remove-worktree <name>                 # confirms before removing
/remove-worktree <name> --force         # skip confirmation
/remove-worktree <name> --delete-branch # also delete the local branch
```

## What it does

1. **Resolve path** — `$(WORKFLOW_WORKTREE_PARENT or parent-of-toplevel)/<repo-name>-<name>`.
2. **Verify it's a worktree** — `git worktree list --porcelain` includes the path.
3. **Confirm** — unless `--force`, show the user what's being removed and wait for explicit `y`.
4. **Run `git worktree remove <path>`** — fails if the worktree has uncommitted changes; user passes `--force` to override.
5. **If `--delete-branch`** — `git branch -d <name>` (or `-D` with `--force`). Refuses to delete a branch not fully merged unless force.
6. **Print summary** — what was removed, whether branch was deleted.

## Execution

```bash
source "$(git rev-parse --show-toplevel)/.claude/scripts/_config.sh"

REPO_ROOT="$(git rev-parse --show-toplevel)"
REPO_NAME="$(basename "$REPO_ROOT")"
PARENT="${WORKFLOW_WORKTREE_PARENT:-$(dirname "$REPO_ROOT")}"
NAME="$1"
TARGET="$PARENT/$REPO_NAME-$NAME"

# Verify it's a worktree
git -C "$REPO_ROOT" worktree list --porcelain | grep -q "^worktree $TARGET$" \
  || { echo "Not a worktree of $REPO_ROOT: $TARGET"; exit 1; }

# Confirm (unless --force)
# [ask user for confirmation here]

# Remove
git -C "$REPO_ROOT" worktree remove "$TARGET"
[ "$DELETE_BRANCH" = "1" ] && git -C "$REPO_ROOT" branch -d "$NAME"

echo "Worktree removed: $TARGET"
```

## Failure handling

- Path not a worktree: refuse with a hint.
- Worktree has uncommitted changes: `git worktree remove` refuses; tell the user to commit/stash or pass `--force`.
- Branch deletion fails (unmerged): tell the user; suggest `-D` (with `--force`) if they really want it gone.

## What this skill will NOT do

- Push or sync anything.
- Delete the remote branch.
- Touch the main clone's working state.

## Companion skills

- **`add-worktree`** — create one.
- **`list-worktrees`** — see what's there.
