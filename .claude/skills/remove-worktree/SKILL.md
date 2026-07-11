---
name: remove-worktree
description: Tear down a git worktree created by `/add-worktree`. Confirms before removing (unless `--force`). Removes the directory via `git worktree remove`, with a local-base "unlanded work" safety gate and a detached-HEAD rescue ref so a `--force` removal never silently loses commits. Deleting the branch is opt-in.
---

# remove-worktree

```bash
/remove-worktree <name>                 # confirms before removing; refuses if there's unsaved/unlanded work
/remove-worktree <name> --force         # remove anyway (uncommitted OR unlanded work will be lost)
/remove-worktree <name> --delete-branch # also delete the local branch (if merged into local <base>)
/remove-worktree <name> --no-rescue     # with --force on a DETACHED worktree, skip stamping a rescue ref
```

## What it does

1. **Resolve path** — `$(WORKFLOW_WORKTREE_PARENT or parent-of-toplevel)/<repo-name>-<name>`.
2. **Verify it's a worktree** — `git worktree list --porcelain` includes the path.
3. **Safety check** — refuse (unless `--force`) if the worktree has uncommitted changes OR commits not yet in the **local** base branch (`$WORKFLOW_BASE_BRANCH`). This repo is local-first — `origin/<base>` is frozen (advanced only by a human-gated `/base-push`), so "not on any remote" is the wrong test; local `<base>` is authoritative.
4. **Detached-HEAD rescue** — if the worktree is DETACHED with unlanded commits and is being `--force`-removed, stamp a `wt-rescue-<name>-<shortsha>` branch at its HEAD SHA first so the commits stay reachable (unless `--no-rescue`). Gate the removal on the rescue ref actually existing.
5. **If it is a fleet agent: STOP IT FIRST, then deregister** — read the machine-local worktrees manifest (path from `fleet_manifest_path`, `.claude/scripts/_fleet.sh`) and look up the entry for this worktree. The read is **three-way and fails CLOSED**:

   | Manifest state | Action |
   |---|---|
   | **absent** | proceed — nothing was ever registered |
   | **present but unreadable / unparseable** | **REFUSE the removal, loudly.** An unknown is not a "no" — the worktree may host a live agent, and removing it out from under a running process is the failure this guard exists to prevent. `--force` does **not** bypass this (it only reaches `down`'s busy gate) |
   | entry with an `agent` field | run `.claude/scripts/fleet-layout.sh down <agent>` **and stop on a non-zero** — busy / skip-marked / failed-kill / self / outside-tmux all refuse, and each one means the agent is still running. Surface `down`'s report verbatim. `--force` passes through to `down` (busy gate only) |

   Only after a clean `down` (or a clean "no agent entry"): remove the entry from the manifest — same atomic write as `/add-worktree` (re-read, `<manifest>.tmp.$$`, `mv -f`, carry through every field and top-level key you don't own).

   > `down` refuses outside tmux by design, so removing an **agent** worktree is a tmux-side operation even when the agent is long dead. There is no headless deregister-only path today; that's known future work, not an oversight.

6. **Run `git worktree remove <path>`** (or `--force` if explicitly approved).
7. **If `--delete-branch`** — delete the local branch only if it's fully merged into local `<base>` (or force).
8. **Print summary** — what was removed, whether a fleet agent was stopped + deregistered, rescue ref (if any), whether the branch was deleted.

## Flags

| Flag | Default | Effect |
|------|---------|--------|
| `--force` | off | Allow removal even when the worktree has uncommitted changes or unlanded commits (not in local `<base>`). Maps to `git worktree remove --force`. |
| `--no-rescue` | off | When a DETACHED worktree carries unlanded commits and is being `--force`-removed, skip stamping a rescue branch at its HEAD SHA. Without this flag a rescue ref is created so the detached commits stay reachable. |
| `--delete-branch` | off | Also delete the local branch checked out in the worktree, if it's fully merged into local `$WORKFLOW_BASE_BRANCH` (use `-D` semantics only with `--force`). |

## Execution

### 0. Resolve + verify

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
```

If the resolved path == `$REPO_ROOT` (the main clone), refuse with a hard stop. `git worktree remove` would also refuse, but better to fail fast with a clear message.

### 1. Safety check — uncommitted / unlanded work

This repo is **local-first**: `origin/<base>` is intentionally frozen (advanced only by a human-gated `/base-push`), so "not on any remote" is the wrong test — it false-fires on every clean teardown. Compare against the **local** base ref (`$WORKFLOW_BASE_BRANCH`) instead:

```bash
git -C "$TARGET" status --porcelain                       # uncommitted changes
git -C "$TARGET" log --oneline "$WORKFLOW_BASE_BRANCH..HEAD"   # commits NOT yet in local <base> (unlanded)
```

If either is non-empty AND `--force` was NOT passed, stop:

```
Worktree has unsaved work:
  Uncommitted files:
    M src/foo.ts
  Unlanded commits (not in local <base>):
    abc1234 wip: try a thing

Pass --force to proceed anyway (you'll lose this work), or commit/land first.
```

### 2. Capture branch info + detached-HEAD rescue

```bash
WORKTREE_BRANCH=$(git -C "$TARGET" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
WORKTREE_SHA=$(git -C "$TARGET" rev-parse HEAD 2>/dev/null || echo "")
```

If `WORKTREE_BRANCH == "HEAD"`, the worktree is detached — its commits live ONLY on this detached HEAD. A `git worktree remove --force` orphans them (on no branch → lost at the next `gc`), and the step-1 gate can miss them. So: when the worktree is DETACHED and `git log "$WORKFLOW_BASE_BRANCH..HEAD"` is non-empty, before a `--force` removal STAMP a rescue ref at the captured SHA so the commits stay reachable (unless `--no-rescue`):

```bash
if [ "$WORKTREE_BRANCH" = "HEAD" ] && [ -n "$FORCE" ] && [ -z "$NO_RESCUE" ]; then
  UNLANDED=$(git -C "$TARGET" log --oneline "$WORKFLOW_BASE_BRANCH..HEAD")
  if [ -n "$UNLANDED" ]; then
    SHORTSHA=$(git -C "$TARGET" rev-parse --short HEAD)
    RESCUE_BRANCH="wt-rescue-${NAME}-${SHORTSHA}"
    git -C "$REPO_ROOT" branch "$RESCUE_BRANCH" "$WORKTREE_SHA"
    # Gate the upcoming --force removal on the rescue ref actually existing — if the
    # branch wasn't created, do NOT proceed (the detached commits would be orphaned).
    # Makes "commits preserved" airtight. ("already exists" at this SHA is benign —
    # show-ref still passes, so we proceed.)
    if ! git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/$RESCUE_BRANCH"; then
      echo "Rescue ref $RESCUE_BRANCH was NOT created — aborting removal to avoid orphaning"
      echo "the detached commits. Branch them manually (git -C \"$REPO_ROOT\" branch <name> $WORKTREE_SHA)"
      echo "then re-run, or re-run with --no-rescue once they're safe."
      exit 1
    fi
  fi
fi
```

Report `$RESCUE_BRANCH` in the summary so the user knows where the detached commits landed.

### 3. Remove the worktree

If the worktree is detached with unlanded commits, the rescue ref from step 2 has already been stamped (unless `--no-rescue`) — its commits survive the `--force` below.

```bash
if [ -n "$FORCE" ]; then
  git -C "$REPO_ROOT" worktree remove --force "$TARGET"
else
  git -C "$REPO_ROOT" worktree remove "$TARGET"
fi
```

### 4. Optionally delete the branch (`--delete-branch`)

Delete the local branch only if it's fully merged into the **local** base branch (local-first — `origin/<base>` is frozen, so no `git fetch`):

```bash
if [ "$DELETE_BRANCH" = "1" ] && [ "$WORKTREE_BRANCH" != "HEAD" ]; then
  if git -C "$REPO_ROOT" branch --merged "$WORKFLOW_BASE_BRANCH" | grep -qE "^\s+$WORKTREE_BRANCH\$"; then
    git -C "$REPO_ROOT" branch -d "$WORKTREE_BRANCH"
    echo "Deleted branch $WORKTREE_BRANCH (fully merged into local $WORKFLOW_BASE_BRANCH)."
  else
    echo "Branch $WORKTREE_BRANCH not deleted — not fully merged into local $WORKFLOW_BASE_BRANCH. Use 'git branch -D $WORKTREE_BRANCH' if you want to drop it anyway."
  fi
fi
```

### 5. Summary

```
✓ Removed worktree: <parent>/<repo>-<name>
  Branch <branch>: deleted (was fully merged into local <base>)         # or "kept" / "n/a (detached)"
  Rescue branch: wt-rescue-<name>-<shortsha> (detached commits preserved) # omit unless a rescue ref was stamped
```

## Failure handling

- **Path not a worktree**: refuse with a hint (`list-worktrees`).
- **Target is the main clone**: hard stop with a clear message.
- **Uncommitted/unlanded work and no `--force`**: surface the diff/log and stop.
- **Rescue ref not created** (detached `--force` path): abort rather than orphan the commits.
- **`git worktree remove` fails**: surface the git error.
- **Branch delete fails (unmerged)**: don't fail the whole skill; note it in the summary and suggest `-D` (with `--force`) if they really want it gone.

## What this skill will NOT do

- Push or sync anything.
- Delete the remote branch.
- Touch the main clone's working state.
- Orphan detached commits — a `--force` removal of a detached worktree with unlanded work stamps a rescue ref first (unless `--no-rescue`) and aborts if it can't.

## Companion skills

- **`add-worktree`** — create one.
- **`list-worktrees`** — see what's there.

---

**Skill Version**: 1.1.0
**Category**: Git Workflow / Dev Environment Setup
_Version history: see [CHANGELOG.md](./CHANGELOG.md)._
