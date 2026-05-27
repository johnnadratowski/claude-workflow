---
name: list-worktrees
description: List every git worktree of the current repo with annotations — branch, last commit, dirty status, and a flag for which one the user is currently inside.
---

# list-worktrees

Show all worktrees of the current repo, formatted for human reading.

## What it shows

For each worktree:

- **Path** (relative to the repo's parent for clarity)
- **Branch** (or `(detached)`)
- **Last commit** — short SHA + subject
- **Dirty?** — uncommitted changes (working tree or index)
- **(current)** marker if it's the worktree the user is calling from

## Execution

```bash
REPO_ROOT="$(git rev-parse --show-toplevel)"
CURRENT_WT="$REPO_ROOT"

git -C "$REPO_ROOT" worktree list --porcelain | awk '
  /^worktree / { wt=$2; next }
  /^HEAD / { head=$2; next }
  /^branch / { branch=$2; next }
  /^detached/ { branch="(detached)"; next }
  /^$/ {
    if (wt) {
      printf "%s\t%s\t%s\n", wt, branch, head
      wt=""; branch=""; head=""
    }
  }
' | while IFS=$'\t' read -r wt branch head; do
  marker=""
  [ "$wt" = "$CURRENT_WT" ] && marker=" (current)"
  short_sha=$(git -C "$wt" rev-parse --short HEAD 2>/dev/null)
  subject=$(git -C "$wt" log -1 --pretty=%s 2>/dev/null)
  dirty=$([ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ] && echo " [dirty]")
  printf "%s%s\n  branch=%s  last=%s %q%s\n" \
    "$wt" "$marker" "$branch" "$short_sha" "$subject" "$dirty"
done
```

## Output example

```
/Users/me/code/myproject (current)
  branch=main  last=a1b2c3d "Initial commit"
/Users/me/code/myproject-feat-1
  branch=feat-1  last=e4f5g6h "Add user model"
/Users/me/code/myproject-pr-1
  branch=pr-1  last=a1b2c3d "Initial commit" [dirty]
```

## What this skill will NOT do

- Modify any worktree state.
- Fetch or talk to origin.
- Annotate with branch upstream / ahead-behind info (could be added; not in v1).

## Companion skills

- **`add-worktree`** — create one.
- **`remove-worktree`** — remove one.
