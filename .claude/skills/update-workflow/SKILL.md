---
name: update-workflow
description: >-
  Pull workflow-machinery updates from the upstream claude-workflow clone into
  THIS repo. Syncs the shared .claude/ machinery (agent-roles, hooks, scripts,
  workflow skills, settings.json.example), leaves project-owned files alone
  (active settings.json, workflow.config, base-test gates, the generated tickets
  skill), and FLAGS locally-customized files instead of clobbering them. Use when
  claude-workflow has new commits you want to adopt — "pull the latest workflow
  updates", "sync the workflow machinery", "update-workflow".
---

# /update-workflow — sync machinery from the upstream claude-workflow

Brings new `claude-workflow` commits into the **consuming** repo you're in. It is
the encoded, repeatable version of the manual "diff the two `.claude/` trees and
copy the differences over" dance. Backed by
[`.claude/scripts/update-workflow.sh`](../../scripts/update-workflow.sh) — one
allow-listed command does the mechanical work; you apply judgment on what it
flags.

> Running this **inside `claude-workflow` itself is a no-op** — this repo is the
> source, so there's nothing upstream of it.

## What it does / doesn't touch

- **Syncs** (from upstream `HEAD`): everything tracked under `.claude/` —
  `agent-roles/`, `hooks/`, `scripts/`, the workflow `skills/`, and
  `settings.json.example`.
- **Never touches** (project-owned): the active `.claude/settings.json`,
  `.claude/workflow.config`, `.claude/skills/base-test/SKILL.md` (your project's
  gate commands), the generated `.claude/skills/tickets/` skill, and any glob in
  `WORKFLOW_SYNC_EXCLUDE`.
- **Flags, never clobbers:** a shared file the consuming repo has *locally
  customized* (differs from both upstream HEAD and the last-synced version) is
  reported as **DIVERGED** and left untouched for you to reconcile by hand.
- **Out of scope:** shared docs under `docs/` and `README.md`/`CLAUDE.md` — these
  drift per-project, so reconcile prose by hand if upstream changed it.

## The sync marker

`.claude/.workflow-sync` records the last-synced upstream short-SHA. It lets the
script (a) list exactly which upstream commits are landing and (b) distinguish a
**pristine** shared file (matches the last-synced version → safe to
fast-forward) from a **locally-customized** one (flag it). First run with no
marker is conservative: missing files are added, but any file that already
differs is flagged rather than overwritten. After a successful run the marker is
advanced to upstream HEAD.

## Configure (`.claude/workflow.config`)

```sh
# Path to the upstream claude-workflow clone. If unset, the script auto-discovers
# a sibling directory named 'claude-workflow' next to this repo.
WORKFLOW_UPSTREAM_PATH="$HOME/git/claude-workflow"

# Optional: extra space-separated path globs to never sync (in addition to the
# built-in project-owned set).
# WORKFLOW_SYNC_EXCLUDE=".claude/skills/my-custom-skill .claude/hooks/local-only.sh"
```

## How to run

1. **Preview** (recommended first): dry-run shows the incoming commits + the
   new/updated/skipped/diverged breakdown, writing nothing.
   ```bash
   "$(git rev-parse --show-toplevel)/.claude/scripts/update-workflow.sh" --check
   ```
2. **Apply:**
   ```bash
   "$(git rev-parse --show-toplevel)/.claude/scripts/update-workflow.sh"
   ```
   (Override discovery with `--upstream <path>` if the clone isn't a sibling and
   the config knob isn't set.)
3. **Reconcile** any **DIVERGED** files by hand — view the upstream change with
   `git -C <upstream> diff <marker>..HEAD -- <path>` and merge the relevant bits
   into the local version.
4. **Verify + commit.** Inspect `git status` / `git diff`. If the TODO/index
   tooling changed, run `node .claude/scripts/gen-todos.mjs --check`. Then commit
   on your branch (e.g. `chore: sync workflow machinery from claude-workflow`).
   The skill does **not** commit for you.

## Propagating to the fleet

In a multi-agent project the coordinator typically runs this on its `<base>-cc`
branch, commits, lands into the base (`/base-push` or `/base-merge up`), then has
the peers pick it up with a `/base-merge down` (drive that with `/agent-fanout`).
The machinery files live under `.claude/`, which is tracked, so they propagate
through the normal base merge-down like any other change.

## Notes

- The script is idempotent: re-running when already current reports
  "up-to-date" and advances nothing.
- It only ever *adds or updates* files from upstream — it never deletes a file
  the consuming repo has that upstream lacks (e.g. your generated `tickets`
  skill), so project-only machinery is safe.
