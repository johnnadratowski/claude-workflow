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
6. **Seed `.claude/settings.local.json`** — it's gitignored (per-engineer, not inherited via git), so a fresh worktree has none; copy the main clone's `.claude/settings.local.json` if present, else `.claude/settings.local.json.example`. The shared guardrails + machinery grants live in the committed `settings.json`, so the seed just carries personal allows and prevents prompt-flooding in the new worktree.
7. **Seed `.claude/workflow.config.local`** — same reason as step 6, and just as load-bearing: it's gitignored, so a fresh worktree has **none**, and `_config.sh` resolves its root to the **worktree** (`git rev-parse --show-toplevel`), not the main clone. A worktree without it reads no `WORKFLOW_BASE_BRANCH` (⇒ **solo mode**, the `base-*` skills disable themselves) and no `WORKFLOW_FLEET_HOME_SESSION` (⇒ each agent's SessionStart `name-windows` targets the default session and **silently orders nothing**). Run:

   ```bash
   MAIN="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"   # NOT $WORKFLOW_MAIN_PATH:
   # that defaults to the CALLER's own toplevel (_config.sh), so an agent running this from a
   # worktree that has no .local would resolve the source to that empty worktree and seed nothing.
   .claude/scripts/workflow-local.sh seed "$MAIN" "$TARGET"
   ```

   **A non-zero here FAILS the worktree, loudly** — never a silent continue. Shipping a worktree with no `.local` is exactly the broken state the seed exists to prevent, and an operator who saw "worktree created" would believe propagation was handled. (The script copies every key except the documented **per-clone** ones — e.g. `WORKFLOW_DOCS_URL`, which is per-lane and must not propagate — and never overwrites an existing `.local`.)

8. **Register it as a fleet agent** (unless `--no-agent`) — ask via `AskUserQuestion` whether this worktree is a fleet agent; `--agent[=<name>]` skips the ask (that's what `/base-initialize` passes). If yes, add an entry to the machine-local worktrees manifest — the path comes from `fleet_manifest_path` (`.claude/scripts/_fleet.sh`; `WORKFLOW_WORKTREES_MANIFEST`, else `~/.config/<main-clone-basename>-worktrees.json`):

   ```json
   { "path": "<target>", "branch": "<name>", "agent": "<prefixed-agent-name>", "active": true }
   ```

   The `agent` value carries `WORKFLOW_AGENT_NAME_PREFIX` — that's the name the session actually registers under. `/fleet-layout boot` enumerates this file, so the next `boot` spins the worktree up with a full cell.

   **Write it atomically and preserve what you don't own**: re-read the manifest immediately before merging (a concurrent `add`/`remove` must not be clobbered), serialize to `<manifest>.tmp.$$`, then `mv -f`. Carry through **every field and top-level key you didn't write** — other tools store their own state in this file, and a rewrite that only knows today's fields silently drops tomorrow's.

9. **Run setup** — if `WORKFLOW_WORKTREE_SETUP_CMD` is set and `--no-setup` wasn't passed, run it in the new worktree (`cd <target> && eval "$WORKFLOW_WORKTREE_SETUP_CMD"`). Surface failures; don't abort the worktree creation.
10. **Print summary** — path, branch, what was copied/run, whether it was registered as a fleet agent, the `cd` command to enter it.

> **Pre-existing worktrees don't get the seed** — it runs at creation only. To top one up:
> `.claude/scripts/workflow-local.sh seed "$MAIN" /path/to/existing-worktree`.

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

## Never check out the base branch — and the command-and-control worktree

**Never check out the literal base branch (`$WORKFLOW_BASE_BRANCH`) in a worktree.** The
local-first merge helper (`merge_into_branch_local` in `base-push`) checks the base out in a
transient worktree; a persistent checkout elsewhere makes `git worktree add <base>` fail for
*everyone*, silently breaking promotion across the fleet. Any other branch is safe.

A **command-and-control (coordinator) worktree** — an agent that orchestrates the
feature/PR/test agents rather than owning a lane — rides a dedicated **`<base>-cc`** branch
(e.g. `main-cc`), created from `origin/<base>`:

```
/agent-fanout            # (later) the orchestration the cc drives
/add-worktree cc --branch <base>-cc --from origin/<base>
```

(then `/agent-rename cc` so it registers as `cc` and picks up the coordinator role.)
`<base>-cc` keeps the cc off the trunk while still being a normal branch — so the cc can also
do feature work on it and merge up into the base like any feature agent when handed a coding
task (see `agent-roles/coordinator.md`). A purely read-only orchestrator can instead detach at
`origin/<base>`. **Never** point a coordinator worktree at the literal base branch.

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
