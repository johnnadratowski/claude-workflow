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
- **Unlanded?** — count of commits not yet in the **local** base branch (`$WORKFLOW_BASE_BRANCH`). This workflow is local-first (`origin/<base>` is frozen behind `/base-push`), so the relevant signal is "not yet landed in local base", **not** "not pushed".
- **(current)** marker if it's the worktree the user is calling from

## Execution

```bash
source "$(git rev-parse --show-toplevel)/.claude/scripts/_config.sh"
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
  # Unlanded: commits on this worktree's HEAD not yet in LOCAL <base> (local-first;
  # origin/<base> is frozen, so this is "not yet landed", not "not pushed").
  unlanded=$(git -C "$wt" log --oneline "$WORKFLOW_BASE_BRANCH..HEAD" 2>/dev/null | wc -l | tr -d ' ')
  [ "${unlanded:-0}" -gt 0 ] && unlanded=" [$unlanded unlanded]" || unlanded=""
  printf "%s%s\n  branch=%s  last=%s %q%s%s\n" \
    "$wt" "$marker" "$branch" "$short_sha" "$subject" "$dirty" "$unlanded"
done
```

## Output example

```
/Users/me/code/myproject (current)
  branch=main  last=a1b2c3d "Initial commit"
/Users/me/code/myproject-feat-1
  branch=feat-1  last=e4f5g6h "Add user model" [2 unlanded]
/Users/me/code/myproject-pr-1
  branch=pr-1  last=a1b2c3d "Initial commit" [dirty]
```

Legend:
- `[N unlanded]`: commits on this branch not yet in local `<base>` (`$WORKFLOW_BASE_BRANCH`) — local-first, so this is "not yet landed", not "not pushed".
- `[dirty]`: uncommitted changes.
- `(current)`: the worktree the user is in right now.

## What this skill will NOT do

- Modify any worktree state.
- Fetch or talk to origin. (The unlanded count is measured against the **local** base ref, never `origin/<base>`.)
- Annotate with branch upstream / ahead-behind info against origin (the local-base "unlanded" count is the relevant signal here).

## Companion skills

- **`add-worktree`** — create one.
- **`remove-worktree`** — remove one.

---

**Skill Version**: 1.1.0
**Category**: Git Workflow / Dev Environment Setup
_Version history: see [CHANGELOG.md](./CHANGELOG.md)._

## The fleet manifest (machine-local)

Fleet agents are enumerated from a machine-local JSON manifest — the file `/fleet-layout`'s `boot`
and `down` read, `/add-worktree` registers into, and `/remove-worktree` deregisters from. Its path
comes from `fleet_manifest_path` (`.claude/scripts/_fleet.sh`): `WORKFLOW_WORKTREES_MANIFEST` when
set, else `~/.config/<main-clone-basename>-worktrees.json` (derived from the git *common* dir, so
every worktree of a clone agrees on it).

```json
{
  "worktrees": [
    { "path": "/Users/me/code/myproject-feat-1", "branch": "feat-1", "agent": "myproject-feat-1", "active": true }
  ]
}
```

| Field | Meaning |
|---|---|
| `path` | absolute worktree path — how `down` targets an agent (names can drift; paths don't) |
| `agent` | the name the session registers under (includes `WORKFLOW_AGENT_NAME_PREFIX`). An entry without it is not a fleet agent |
| `active` | `false` parks a lane: `boot` skips it. **`down` ignores this** — "stop all agents" means all |
| `branch` | informational |

**Every writer owns the whole document.** Re-read the file immediately before merging, write through
`<manifest>.tmp.$$` + `mv -f`, and **carry through every field and top-level key you didn't write** —
a rewrite that knows only today's fields silently drops tomorrow's (and a dropped `agent` field
quietly un-fleets an agent, with no error).

### Per-clone vs per-engineer config

`.claude/workflow.config.local` is seeded from the main clone into each new worktree by
`/add-worktree`. Keys that are **per-clone rather than per-engineer** must NOT propagate — today
that's `WORKFLOW_DOCS_URL` (a per-lane port). They're listed in `PER_CLONE_KEYS` in
`.claude/scripts/workflow-local.sh`; **a new per-clone knob must be added there**, or every worktree
silently inherits one clone's value.
