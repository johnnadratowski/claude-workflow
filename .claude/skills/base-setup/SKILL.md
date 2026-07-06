---
name: base-setup
description: Onboard THIS engineer onto an already-set-up project — opt into fleet mode. Creates a personal coordination base branch off the trunk (origin/master), writes the gitignored .claude/workflow.config.local (base branch, clone path, TODO namespace, optional agent prefix), seeds .claude/settings.local.json, optionally installs the user-level SessionStart hook, and offers to provision feature/review/test agent worktrees (default 1 cc + 3 feature + 2 review + 1 test) with the commands to start them — all skippable for a solo engineer who just wants the base skills to work. Non-destructive (never resets git or scaffolds — that's base-initialize, for NEW projects). Use when a new engineer clones the repo and wants to configure the workflow, or says "set up the workflow / fleet / my base branch".
---

# base-setup — per-engineer workflow setup (opt into fleet mode)

**Run once, per engineer, on an already-configured project clone.** Turns on **fleet mode** by
creating this engineer's personal coordination **base branch** (a branch off the trunk, never the
trunk itself) and writing the machine-specific config to the **gitignored** `workflow.config.local`.

Without this, the repo works in **solo mode**: the base-coordination skills (`/base-merge`,
`/base-push`, `/base-pr`, `/agent-*`) are disabled and `/todo` + `/afk` fall back to plain git +
prompting you. `base-setup` is how you upgrade to the multi-agent, local-first coordination model.

> **NOT `base-initialize`.** `base-initialize` bootstraps a *brand-new* project from a
> `claude-workflow` clone — it **resets `.git`**, installs template docs, and scaffolds code. This
> skill is the opposite: it touches **nothing tracked**, only your gitignored local config +
> (optionally) new worktrees. If the cwd is a fresh `claude-workflow` template, tell the user to run
> `/base-initialize` instead.

## Pre-flight (refuse the wrong context)

```bash
source "$(git rev-parse --show-toplevel)/.claude/scripts/_config.sh"
ROOT="$(git rev-parse --show-toplevel)"
```

Refuse / redirect:
- **Not a git repo**, or **no `origin/master`** (the trunk the base branches off) → stop: "I need a
  git repo with an `origin/master` (or your trunk) to branch from." (Offer to use a different trunk if
  `origin/master` is absent but another default branch exists — `git symbolic-ref refs/remotes/origin/HEAD`.)
- **Looks like a `claude-workflow` template** (`[ -d ./templates/example_docs ]`) → redirect to `/base-initialize`.
- **Already fleet-configured** (`[ "$WORKFLOW_FLEET_MODE" = 1 ]` AND `workflow.config.local` already sets
  `WORKFLOW_BASE_BRANCH`) → this engineer is already set up; confirm before re-running (`--reconfigure`),
  and never clobber an existing base branch that has unpushed commits.

## Phase 1 — Identity (AskUserQuestion)

Collect via the **`AskUserQuestion`** tool (native multiple-choice; free-form via "Other"):

| Field | Default | Notes |
|---|---|---|
| **Base branch name** | your git local-part (`WORKFLOW_TODO_NS`, e.g. `jnadro52`) or username | Becomes `WORKFLOW_BASE_BRANCH`. This is YOUR coordination branch — pick something personal (your name/handle), **not** `master`/`main`. |
| **Agent name prefix** | none | Only relevant if you'll run agents from more than one project at once (agents share `~/.claude/running-agents/`). Offer: use branch name (no prefix, default) · project name · custom. Becomes `WORKFLOW_AGENT_NAME_PREFIX`. |

Confirm the base name isn't the trunk (`master`/`main`) — refuse and re-ask if it is (that's the whole
point: the base is a personal branch *off* the trunk).

## Phase 2 — Create the base branch off the trunk

The base is a **local ref**, never checked out in a worktree (the coordinator rides `<base>-cc`, agents
ride feature branches). Create it from the trunk without switching to it:

```bash
git fetch origin master        # or the resolved trunk
git branch "$BASE" origin/master   # e.g. git branch jnadro52 origin/master
```

If `origin/master` is unreachable (no network / no remote), fall back to local `master`:
`git branch "$BASE" master`. Do NOT push it — publishing the base is `/base-push`'s human-gated job later.

## Phase 3 — Write `workflow.config.local` (gitignored) + seed `settings.local.json`

Append (or create) `.claude/workflow.config.local` with THIS engineer's machine-specific values. It's
gitignored, so it never ships to anyone else and never touches the committed generic config:

```bash
cat >> "$ROOT/.claude/workflow.config.local" <<EOF
# --- written by /base-setup on $(date +%F) ---
WORKFLOW_BASE_BRANCH="$BASE"
WORKFLOW_MAIN_PATH="$ROOT"          # this clone anchors the transient merge worktrees
# WORKFLOW_TODO_NS derives from your git email if unset; set it here to override.
# WORKFLOW_AGENT_NAME_PREFIX="$PREFIX"   # uncomment if you chose a prefix
EOF
```

Seed the local permission/settings file from the committed example — **only if the engineer doesn't
already have one** (never clobber their existing gitignored `settings.local.json`). The `ask`
guardrails + machinery allow-grants live in committed `settings.json`; the example carries sensible
personal defaults. (`settings.local.json.example` is added by the `settings.local.json`
migration — this copy is a best-effort no-op until then, and must never overwrite an existing file.)

```bash
# Correct precedence: copy ONLY when the dest is absent AND an example exists.
# (`[ -f dest ] || [ -f ex ] && cp` is the buggy form — it runs cp when dest EXISTS.)
if [ ! -f "$ROOT/.claude/settings.local.json" ] && [ -f "$ROOT/.claude/settings.local.json.example" ]; then
  cp "$ROOT/.claude/settings.local.json.example" "$ROOT/.claude/settings.local.json"
fi
```

Re-source `_config.sh` and confirm `WORKFLOW_FLEET_MODE=1` + `WORKFLOW_BASE_BRANCH=$BASE`.

> **This engineer's own empty-example seed ≠ a fleet-wide settings restore.** The copy above is a
> best-effort, non-clobbering seed of *this* clone's personal allow-list from the empty example — an
> engineer configuring their own machine. A **FLEET-WIDE** restore (re-materializing every worktree's
> `settings.local.json` after, e.g., the tracked→gitignored migration wiped their working copies) is a
> **coordinator / human task**, not something an agent does to itself: an agent cannot self-write its
> own permission allow-list (the self-modification guard forbids editing settings/permissions), so a
> coordinator or the human distributes the restore across worktrees out of band. Keep the two distinct.

## Phase 4 — User-level SessionStart hook (optional, ask)

For agents to auto-register/auto-rename when their pane starts `claude`, the **user-level**
`~/.claude/settings.json` needs the `register-agent.sh` `SessionStart` hook. This is per-machine, not
per-repo. Ask via `AskUserQuestion` whether to install it (recommended if they'll run agents); if yes,
back up `~/.claude/settings.json` first, then add the hook idempotently (skip if a `register-agent.sh`
SessionStart entry already exists — mirror `base-initialize` Phase 6). Skip entirely for a solo engineer
who won't spawn agents.

## Phase 5 — Agent provisioning (AskUserQuestion — SKIPPABLE)

Ask up front: **"Set up multiple agents, or just work solo in this one session?"**
- **Solo** → skip the rest; print the summary. Fleet mode is on (base skills work), they just have no peers.
- **Set up agents** → collect counts via `AskUserQuestion` (single-select 0–4), offering the **default
  fleet**: **1 coordinator (cc) + 3 feature + 2 review + 1 test**:
  | Role | Default | Max | Worktree/branch names |
  |---|---|---|---|
  | coordinator | 1 | 1 | `<base>-cc` |
  | feature | 3 | ~4 | `<base>-1`, `<base>-2`, … |
  | review | 2 | 2 | `<base>-pr`, `<base>-pr-2` |
  | test | 1 | 2 | `<base>-test`, `<base>-test-2` |

  Auto-derive `WORKFLOW_TESTING_AGENT` from the first test agent's name (incl. prefix) into
  `workflow.config.local`; if 0 test agents, leave it blank (`/todo`/`/afk` will ask each time).

  For each chosen worktree, invoke **`/add-worktree <name>`** (creates the branch off the base + the
  worktree dir; runs `WORKFLOW_WORKTREE_SETUP_CMD` if set). Then **give the engineer the commands to
  start each agent** (don't force-spawn — per project preference, print them so they choose):
  ```
  tmux new-window -n <name> -c <worktree-path> \; send-keys 'claude' Enter
  ```
  Offer to spawn them via tmux if the engineer is already inside tmux and says yes; otherwise the printed
  commands are the deliverable.

## Summary (always)

Print: fleet mode ON, base = `<base>` (off `origin/master`, local-only until `/base-push`), config in
`workflow.config.local` (gitignored), which agents/worktrees exist + how to start them, and that solo
work needs nothing more — the base skills are now live for this clone. Note that **the committed repo is
untouched** (only your gitignored local files + any new worktrees changed).

## What this skill will NOT do
- Reset `.git`, install template docs, scaffold code, or run `/define-project` (that's `base-initialize`).
- Write to the **committed** `.claude/workflow.config` (only the gitignored `.local`).
- Name the base branch `master`/`main` (refused — the base is personal, off the trunk).
- Push the base to origin (that's `/base-push`, human-gated).

## Companion skills
- **`base-initialize`** — the NEW-project bootstrapper (destructive; resets git). This skill is its
  existing-project, non-destructive counterpart.
- **`add-worktree`** — creates each agent's worktree (Phase 5 calls it).
- **`base-merge` / `base-push` / `base-pr` / `base-test` / `agent-*`** — the fleet skills this setup
  enables (they disable themselves until `WORKFLOW_FLEET_MODE=1`).

---

**Skill Version**: 1.0.0
**Category**: Workflow, Setup
