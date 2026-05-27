---
name: add-worktree
description: Create a new git worktree as a sibling directory of the current repo (e.g. `<repo>-feat-1`). Optionally on a new branch (`--branch <name>` or default to using the worktree name as branch). Optionally copies env-like files from the main clone and runs a setup command (`pnpm install` etc.) — all driven by `WORKFLOW_WORKTREE_*` settings in `.claude/workflow.config`.
---

# add-worktree

Create a new git worktree at `<parent-of-repo>/<repo-name>-<worktree-name>` and optionally seed it with env files + run a setup command.

## Usage

```bash
/add-worktree <name>                                 # create new branch <name> from origin/<base>
/add-worktree <name> --branch <existing-branch>      # check out an existing branch instead
/add-worktree <name> --from <ref>                    # create new branch from <ref> instead of origin/<base>
/add-worktree <name> --no-setup                      # skip the setup command (env-copy still runs)
```

## What it does

1. **Validate name** — lowercase letters, digits, dashes, underscores; ≤ 40 chars; no `..` or `/`.
2. **Resolve target path** — `$(dirname $(git rev-parse --show-toplevel))/$(basename $(git rev-parse --show-toplevel))-<name>`. Refuses if the target already exists.
3. **Pre-flight** — main clone clean enough; `--from` ref resolves; source branch (if `--branch`) exists.
4. **`git worktree add`**:
   - Default: `git worktree add -b <name> <target> <from>` — creates new branch from from-ref.
   - With `--branch`: `git worktree add <target> <branch>` — uses existing branch.
5. **Copy env files** — for each path in `WORKFLOW_WORKTREE_COPY_FILES` (array; defaults to none), copy from the main clone to the new worktree if it exists. Useful for `.env`, `.envrc`, etc. that are gitignored.
6. **Run setup** — if `WORKFLOW_WORKTREE_SETUP_CMD` is set and `--no-setup` wasn't passed, run it in the new worktree (`cd <target> && eval "$WORKFLOW_WORKTREE_SETUP_CMD"`). Surface failures; don't abort the worktree creation.
7. **Print summary** — path, branch, what was copied/run, the `cd` command to enter it.

## Configuration

In `.claude/workflow.config`:

```bash
# Parent directory for new worktrees. Default: parent of git toplevel.
# WORKFLOW_WORKTREE_PARENT="$HOME/code"

# Files to copy from the main clone to each new worktree.
# Useful for env files that are gitignored. Pattern is shell array.
# WORKFLOW_WORKTREE_COPY_FILES=(".env" ".env.local" ".envrc")

# Command to run in the new worktree after creation. Common: dependency install.
# WORKFLOW_WORKTREE_SETUP_CMD="pnpm install --frozen-lockfile"
```

## Execution

```bash
source "$(git rev-parse --show-toplevel)/.claude/scripts/_config.sh"

REPO_ROOT="$(git rev-parse --show-toplevel)"
REPO_NAME="$(basename "$REPO_ROOT")"
PARENT="${WORKFLOW_WORKTREE_PARENT:-$(dirname "$REPO_ROOT")}"
NAME="$1"        # parsed from args
TARGET="$PARENT/$REPO_NAME-$NAME"

# Validate
[[ "$NAME" =~ ^[a-z0-9_-]{1,40}$ ]] || { echo "Invalid name."; exit 1; }
[ -e "$TARGET" ] && { echo "Target exists: $TARGET"; exit 1; }

FROM_REF="${FROM_REF:-origin/$WORKFLOW_BASE_BRANCH}"
git -C "$REPO_ROOT" rev-parse --verify "$FROM_REF^{commit}" >/dev/null || { echo "Bad --from ref"; exit 1; }

# Create
if [ -n "${USE_EXISTING_BRANCH:-}" ]; then
  git -C "$REPO_ROOT" worktree add "$TARGET" "$USE_EXISTING_BRANCH"
else
  git -C "$REPO_ROOT" worktree add -b "$NAME" "$TARGET" "$FROM_REF"
fi

# Copy env files (if configured)
if [ -n "${WORKFLOW_WORKTREE_COPY_FILES+x}" ]; then
  for f in "${WORKFLOW_WORKTREE_COPY_FILES[@]}"; do
    [ -e "$REPO_ROOT/$f" ] && cp "$REPO_ROOT/$f" "$TARGET/$f"
  done
fi

# Run setup (if configured + not opted out)
if [ -n "${WORKFLOW_WORKTREE_SETUP_CMD:-}" ] && [ "${SKIP_SETUP:-0}" != "1" ]; then
  ( cd "$TARGET" && eval "$WORKFLOW_WORKTREE_SETUP_CMD" )
fi

echo "Worktree created: $TARGET"
echo "Branch: $NAME"
echo "cd $TARGET"
```

## Failure handling

- Name validation fail: report which rule, don't create.
- Target exists: refuse; suggest `/remove-worktree <name>` first.
- `--from` ref doesn't resolve: stop before any change.
- `git worktree add` failure: surface git's output verbatim.
- Env-copy failure: warn but continue (env files are optional).
- Setup-cmd failure: warn but leave the worktree; user can debug.

## What this skill will NOT do

- Auto-allocate ports or dev-environment lanes — that's project-specific. Wire it into `WORKFLOW_WORKTREE_SETUP_CMD` if you need it.
- Touch the main clone's working state.
- Push the new branch to origin (the user does that explicitly via `/base-push` when ready).

## Companion skills

- **`remove-worktree`** — tear down a worktree.
- **`list-worktrees`** — list all worktrees.
- **`base-initialize`** — uses this skill repeatedly to set up feature/PR/test worktrees.
