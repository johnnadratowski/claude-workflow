---
name: base-initialize
description: Bootstrap a new project from a `claude-workflow` clone. Runs once at project start. Resets `.git` (the workflow's history is irrelevant to the new project), installs `docs/` from `templates/example_docs`, installs `CLAUDE.md` from the template, writes `.claude/workflow.config`, installs the project-level agent hooks + seeds the generated TODO index, asks how many feature / PR / test agents to spin up, auto-installs the user-level `SessionStart` hook into `~/.claude/settings.json` (with backup) so spawned agents auto-register, creates that many worktrees, opens tmux panes for each, starts `claude` in each, then hands off to the `define-project` orchestrator skill — which drives product → architect → QA → deploy/security → TODO-taxonomy dialogs, populates the docs with real content, and scaffolds the code + tests + CI.
---

# base-initialize

**Run once, at the very start of a new project.**

Bootstraps a fresh project from a `claude-workflow` clone:

1. Resets git, installs the template docs + CLAUDE.md, writes the workflow config
2. Asks how many feature / PR / test agents to set up
3. Installs the user-level `SessionStart` hook into `~/.claude/settings.json`
4. Hands off to `/define-project` — an orchestrator that drives product, architecture, QA, deployment+security, and TODO-taxonomy dialogs with the user, populates the docs with real content, and scaffolds code + tests + CI
5. Commits everything `define-project` produced
6. **Then** creates worktrees + opens tmux panes + starts `claude` in each — so the feature / PR / test agents branch from a fully-populated commit instead of an empty template

After this skill finishes, the user has a working multi-agent setup, project-specific docs, a code + test scaffold, and ticketed feature specs.

## Pre-flight

Verify the cwd is a `claude-workflow` clone:

```bash
[ -d ./templates/example_docs ] && [ -d ./.claude/skills/base-push ] \
  && [ -f ./workflow.config.example ] \
  || { echo "Doesn't look like a claude-workflow clone."; exit 1; }
```

Verify the user is inside `tmux` (we'll need to spawn panes):

```bash
[ -n "${TMUX:-}" ] || { echo "Run me from inside a tmux session — I'll spawn panes for each agent."; exit 1; }
```

## Phase 1: Project metadata

Identity-only questions — nothing about the tech stack, dependency-install command, or env files. Those are owned by `/define-architect` in Phase 7 (and it writes them into `.claude/workflow.config` itself). Keeping Phase 1 minimal means the user doesn't answer the same question twice.

Use `AskUserQuestion` to collect, in this order:

| Field | Default | Notes |
|---|---|---|
| Project name | `basename $(pwd)` | Becomes the H1 in CLAUDE.md; also the prefix for worktree directory names. |
| Description | `(empty)` | One-paragraph; goes into CLAUDE.md after the heading. |
| Base branch | `main` | Becomes `WORKFLOW_BASE_BRANCH`. |
| Git remote URL | `(none)` | "Do you have a remote you want to push to?" If yes, captured as a URL string and applied in Phase 2 via `git remote add origin <url>`. If no, skip — the user can add a remote later. |
| Exposes an API? | (asks) | "Does this project expose an API (HTTP/REST/RPC) callers depend on?" Yes/No. **No** → Phase 3 deletes `docs/api.md`, `docs/api-conventions.md` (and any `docs/swagger.json`). **Yes** → they're kept; `/define-architect` documents the conventions + wires the spec-generation command. |
| Agent name prefix | (asks) | "Multiple projects share `~/.claude/running-agents/`, so prefixing agent names is recommended if you'll run agents from more than one project at a time." Four-option `AskUserQuestion` (see below). Becomes `WORKFLOW_AGENT_NAME_PREFIX`. |

### Agent prefix — four options

Use `AskUserQuestion` with these choices:

1. **Use the project name** — `WORKFLOW_AGENT_NAME_PREFIX="<project-name>-"` (e.g. agents become `myproj-feat-1`, `myproj-test-1`). **Recommended** if the project name is distinctive.
2. **Use the current folder name** — `WORKFLOW_AGENT_NAME_PREFIX="$(basename $(pwd))-"`. Useful when the project name differs from the folder, and the folder name is the better disambiguator.
3. **Custom prefix** — follow-up question: "Enter prefix" (string). Append a trailing dash if the user didn't include one. Becomes `WORKFLOW_AGENT_NAME_PREFIX="<their-string>-"`.
4. **No prefix** — leave `WORKFLOW_AGENT_NAME_PREFIX` commented out in the config. Agents use their branch name directly (`feat-1`, `pr-1`, etc.).

The chosen prefix is sanitized the same way `register-agent.sh` sanitizes names: lowercase alnum / dash / underscore only. The hook also runs its own sanitization, so don't worry about edge cases here — pass the user's literal answer in.

Then **confirm** before proceeding:

> "I'm about to delete the existing `.git/` directory and reinitialize. Continue?"

Hard-stop if the user declines.

## Phase 2: Repo reset

```bash
rm -rf .git
git init -b "$BASE_BRANCH"

# Optionally wire the remote captured in Phase 1.
if [ -n "$REMOTE_URL" ]; then
  git remote add origin "$REMOTE_URL"
fi
```

If the user has `~/.gitconfig` set, the init picks up their identity. If they don't, leave it for them to configure later.

If a remote was added, the first push will be `git push -u origin <base>` — `/base-push` from a feature worktree handles that automatically.

## Phase 3: Install docs + CLAUDE.md + config

```bash
# Docs: copy the example_docs as a starting point. User will customize in phase 7.
mkdir -p docs
cp -r templates/example_docs/. docs/

# CLAUDE.md: replace placeholders with collected metadata.
cp templates/CLAUDE.md CLAUDE.md
sed -i.bak "s|<Project name>|$PROJECT_NAME|g" CLAUDE.md
sed -i.bak "s|<One-paragraph description.*|$DESCRIPTION|" CLAUDE.md
rm CLAUDE.md.bak

# If the project has no API surface, drop the API docs (kept otherwise).
if [ "$EXPOSES_API" != "yes" ]; then
  rm -f docs/api.md docs/api-conventions.md docs/swagger.json
fi

# Workflow config
cp workflow.config.example .claude/workflow.config

# Set the base branch
sed -i.bak "s|WORKFLOW_BASE_BRANCH=\"main\"|WORKFLOW_BASE_BRANCH=\"$BASE_BRANCH\"|" .claude/workflow.config

# Set the agent name prefix if the user chose one (options 1–3).
# Empty $AGENT_PREFIX = "no prefix" = leave commented.
if [ -n "$AGENT_PREFIX" ]; then
  sed -i.bak "s|^# WORKFLOW_AGENT_NAME_PREFIX=.*|WORKFLOW_AGENT_NAME_PREFIX=\"$AGENT_PREFIX\"|" .claude/workflow.config
fi

# WORKFLOW_WORKTREE_SETUP_CMD and WORKFLOW_WORKTREE_COPY_FILES are
# intentionally left commented at this point — /define-architect (Phase 7)
# fills them in once the user has locked the stack, since it's the skill
# that actually knows the install command and the env-file shape.

rm -f .claude/workflow.config.bak

# Install the PROJECT-level settings (deny rules + the agent hooks:
# UserPromptSubmit→mark-busy, Stop→drain-inbox, SessionEnd→unregister). These
# fire after project settings load, so unlike SessionStart they belong here.
# Merge into an existing .claude/settings.json if the user already has one; else
# copy the example wholesale.
if [ -f .claude/settings.json ] && command -v jq >/dev/null 2>&1; then
  tmp=$(mktemp)
  jq -s '.[0] * .[1]' .claude/settings.json .claude/settings.json.example > "$tmp" && mv "$tmp" .claude/settings.json
else
  cp .claude/settings.json.example .claude/settings.json
fi

# Seed the generated TODO index from the shipped docs/todos/ (milestones.json + README).
node .claude/scripts/gen-todos.mjs || echo "gen-todos failed — check docs/todos/milestones.json"

# Remove now-redundant template files
rm -rf templates/
rm -f workflow.config.example .claude/settings.json.example .claude/settings-user-level.json.example
rm -f README.md   # original was the workflow's README; user will write their own
```

(macOS `sed -i ''` vs GNU `sed -i` differ — use `-i.bak` + `rm *.bak` pattern as a portable middle ground.)

> The whole `.claude/` tree is copied as-is into the project, so the agent hooks
> (`register-agent.sh`, `drain-inbox.sh`, `mark-busy.sh`, `unregister-agent.sh`), the
> scripts (`agent-send.sh`, `agent-broadcast.sh`, `inbox-watcher.sh`, `gen-todos.mjs`),
> the **agent-role startup files** (`.claude/agent-roles/{coordinator,review,feature,test}.md`),
> and every skill ride along automatically — no per-file copy needed here.

## Phase 4: Initial commit

```bash
git add -A
git commit -m "Initial commit: $PROJECT_NAME"
```

## Phase 5: Worktree counts

Use `AskUserQuestion` (three questions, single-select 0/1/2/3/4+):

- "How many **feature** agents?" (default 1, max ~4)
- "How many **PR review** agents?" (default 1, max 2)
- "How many **test** agents?" (default 1, max 2)

Compute the worktree names from these counts:

- `feat-1`, `feat-2`, ... up to feature count
- `pr-1`, `pr-2`, ... up to PR count
- `test-1`, `test-2`, ... up to test count

Total worktrees = sum of the three counts. If 0, skip **Phase 9** (worktree creation) and **Phase 10** (tmux panes) — the user can run `/add-worktree` later to add them. Phases 6 (SessionStart hook) and 7 (`/define-project` handoff) still run; the hook is useful for future sessions and `/define-project` is the main reason to bootstrap regardless of multi-agent setup.

**Auto-derive the testing agent** from the answer. If `test count >= 1`, set `WORKFLOW_TESTING_AGENT` to the name of the first test agent — which **includes the prefix** from Phase 1 if one was chosen, since that's what the agent actually registers as:

```bash
if [ "$TEST_COUNT" -ge 1 ]; then
  full_tester_name="${AGENT_PREFIX}test-1"   # e.g. "myproj-test-1" or just "test-1"
  sed -i.bak "s|^# WORKFLOW_TESTING_AGENT=.*|WORKFLOW_TESTING_AGENT=\"$full_tester_name\"|" .claude/workflow.config
  rm -f .claude/workflow.config.bak
fi
```

This change isn't committed yet — it'll be picked up by the final commit in Phase 8 along with everything `define-project` produces. If the user creates zero test agents, `WORKFLOW_TESTING_AGENT` stays blank and `/todo continue` will ask the user for the target each time.

## Phase 6: Install the user-level SessionStart hook

**Runs before worktree creation** because the moment a worktree's pane fires `claude` (Phase 10), the `SessionStart` hook needs to already be in place — otherwise the agent won't auto-register/auto-rename.

This phase **mutates `~/.claude/settings.json` directly** (with a timestamped backup) rather than asking the user to do it themselves, then reports exactly what changed. `SessionStart` hooks have to live at user level — Claude Code rejects them in project settings because they fire before project settings load.

### Install logic

```bash
SETTINGS="$HOME/.claude/settings.json"
mkdir -p "$(dirname "$SETTINGS")"

# 1. Detect whether the register-agent.sh hook is already wired up.
already_installed=0
if [ -f "$SETTINGS" ] && command -v jq >/dev/null 2>&1; then
  already_installed=$(jq -r '
    [.hooks.SessionStart[]?.hooks[]?.command // empty]
    | map(select(test("register-agent.sh")))
    | length
  ' "$SETTINGS" 2>/dev/null || echo 0)
fi

# 2. Choose a path: skip / merge / fallback-to-manual.
if [ "${already_installed:-0}" -gt 0 ]; then
  install_result="skipped"
  install_msg="SessionStart hook for register-agent.sh already present in $SETTINGS — no changes."
elif command -v jq >/dev/null 2>&1; then
  # Back up any pre-existing file before we touch it.
  if [ -f "$SETTINGS" ]; then
    backup="$SETTINGS.bak.$(date +%Y%m%d-%H%M%S)"
    cp "$SETTINGS" "$backup"
  else
    echo '{}' > "$SETTINGS"
    backup=""
  fi

  # The literal command we want to install. Single-quoted in shell so the
  # nested ${CLAUDE_PROJECT_DIR:-$PWD} survives untouched into the JSON.
  HOOK_CMD='bash -c '\''r=$(git -C "${CLAUDE_PROJECT_DIR:-$PWD}" rev-parse --show-toplevel 2>/dev/null) || exit 0; [ -x "$r/.claude/hooks/register-agent.sh" ] || exit 0; exec bash "$r/.claude/hooks/register-agent.sh" sessionstart'\'''

  tmp=$(mktemp)
  if jq --arg cmd "$HOOK_CMD" '
    .hooks //= {} |
    .hooks.SessionStart //= [] |
    .hooks.SessionStart += [{matcher: "", hooks: [{type: "command", command: $cmd}]}]
  ' "$SETTINGS" > "$tmp" && [ -s "$tmp" ]; then
    mv "$tmp" "$SETTINGS"
    install_result="installed"
    if [ -n "$backup" ]; then
      install_msg="Installed SessionStart hook → $SETTINGS (backup: $backup)"
    else
      install_msg="Created $SETTINGS with SessionStart hook (no prior file to back up)"
    fi
  else
    rm -f "$tmp"
    install_result="failed"
    install_msg="jq merge into $SETTINGS failed — settings unchanged. Falling back to manual install instructions."
  fi
else
  install_result="no-jq"
  install_msg="jq not installed; can't safely auto-merge $SETTINGS. Falling back to manual install instructions."
fi
```

### Report what happened

Print `install_msg` to the user immediately so they see exactly what happened to their home-dir settings. Examples of what they should see:

- `Installed SessionStart hook → /Users/you/.claude/settings.json (backup: /Users/you/.claude/settings.json.bak.20260528-143012)`
- `Created /Users/you/.claude/settings.json with SessionStart hook (no prior file to back up)`
- `SessionStart hook for register-agent.sh already present in /Users/you/.claude/settings.json — no changes.`

### Fallback (`install_result` = `failed` or `no-jq`)

Print the literal snippet so the user can merge it manually, then continue (don't hard-stop — they can finish bootstrap and wire the hook later; spawned agents will just need a one-time `/agent-rename <name>` per pane until they do):

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bash -c 'r=$(git -C \"${CLAUDE_PROJECT_DIR:-$PWD}\" rev-parse --show-toplevel 2>/dev/null) || exit 0; [ -x \"$r/.claude/hooks/register-agent.sh\" ] || exit 0; exec bash \"$r/.claude/hooks/register-agent.sh\" sessionstart'"
          }
        ]
      }
    ]
  }
}
```

The same snippet ships at `.claude/settings-user-level.json.example` in this project — point the user there too.

Capture `install_result` so Phase 11 (report) can echo it back as part of the final summary.

## Phase 7: Hand off to `/define-project`

The repo is reset, configs are written, and the user-level `SessionStart` hook is installed — but **worktrees haven't been spawned yet**. That's deliberate: `/define-project` is going to populate `docs/`, scaffold the code, generate `.claude/skills/tickets/SKILL.md`, and seed tickets — all in the main clone's working tree. We want the eventual worktrees to branch from a commit that already contains all of that, so feature / PR / test agents start with the complete project context (not template stubs).

Invoke it via the Skill tool:

```
Skill: define-project
```

`define-project` will:

1. Run `define-product` — interactive product dialog + numbered feature specs under `docs/specs/`
2. Run `define-architect` — interactive technology / code-conventions dialog + initial code scaffold (package manifest, lint config, entrypoints, `.env.example`, etc.)
3. Run `define-qa` — interactive testing-strategy dialog + test scaffold
4. Run `define-deploy` — interactive deployment + security dialog + CI workflow / Dockerfile / platform config
5. Run `define-tickets` — tailor the built-in TODO system's taxonomy + conventions (areas → ID prefixes, priorities, milestones, definition-of-ready/done, spec↔TODO link) by editing `docs/todos/milestones.json`. The TODO files under `docs/todos/` are the tracker — there's no external provider and no generated `/tickets` skill.

Each subskill has its own subagent-driven critical review and user-signoff gate, so the user can iterate on each domain before moving to the next.

Return to Phase 8 (final commit) once `define-project` signals completion. If the user calls out early via the orchestrator's "skip ahead" path, also continue — partial work is fine; they can re-enter `/define-project` later and it will detect the existing state.

## Phase 8: Final commit

```bash
git add -A
git commit -m "docs: project-specific content from initialize interview"
```

This single commit captures everything `define-project` produced — docs, code scaffold, test scaffold, CI/Dockerfile, and the customized TODO taxonomy (`docs/todos/milestones.json`). Worktrees created in Phase 9 will branch from this commit, so each one starts with the full project.

## Phase 9: Create worktrees

For each worktree name from Phase 5, invoke `/add-worktree <name>`:

- Path lands at `$(dirname $(pwd))/$(basename $(pwd))-<name>`
- Branch `<name>` is created from the current base branch — which now points at the Phase 8 commit, so the worktree's initial state already contains all the docs + scaffold + generated skills from `define-project`
- If `WORKFLOW_WORKTREE_SETUP_CMD` was set by `/define-architect` in Phase 7 (it writes the install command into `.claude/workflow.config` once the user locks the stack), each `/add-worktree` invocation runs it inside the new worktree — so dependencies install automatically as each worktree comes up. Stream the install output; surface failures but don't abort the worktree (it stays half-set-up so the user can debug). If the user skipped `/define-architect`, the line stays commented and no setup command runs.

After all worktrees are created, summarize the layout.

## Phase 10: Open tmux panes

For each worktree:

```bash
tmux new-window -n "$NAME" -c "$WORKTREE_PATH"
tmux send-keys -t "$NAME" "claude" Enter
```

Each new claude session auto-registers via the user-level `SessionStart` hook installed back in Phase 6. The agent name comes from its branch (i.e., the worktree name).

Alternative if the user prefers splits over windows: ask them via `AskUserQuestion` "New windows or splits?" before this phase.

## Phase 11: Report

Tell the user:

- Project initialized at `<path>`
- Branch: `<base-branch>`
- Worktrees created: list each path
- Agents started: list each pane / window name
- Docs populated: which docs were customized; which (if any) are still using the example content
- SessionStart hook: echo back the `install_msg` captured in Phase 6 so the user has a permanent record of what happened to `~/.claude/settings.json` (installed + backup path, created fresh, already-present, or failed/no-jq with the manual-merge reminder)
- **Next step**: add your first todo with `/todo Add my first feature` (or similar), then `/todo do next`.
- **Workflow reminder**: the doc-drift loop (in `/todo`) will keep growing `docs/best-practices.md` as the project evolves — don't pre-fill it.

## Failure handling

- **Pre-flight fails** (not a claude-workflow clone, not in tmux): hard stop; explain.
- **User declines reset confirmation**: hard stop; no changes.
- **`git init` or any sed fails**: stop and report — the user's repo state could be partial; tell them which file to inspect.
- **`/add-worktree` fails for one or more worktrees**: continue with the rest; report which failed at the end. The user can re-run `/add-worktree` manually for the missed ones.
- **`tmux new-window` fails**: skip that pane; report. The user can `cd <worktree>` and `claude` manually.
- **`/define-project` skip-ahead**: if the user calls out early in Phase 7 (e.g., "skip the rest, let's just get the worktrees up"), accept it. Proceed to Phase 8 (final commit) with whatever the orchestrator produced so far — the user can re-enter `/define-project` later and it detects existing state. Skipping `define-project` entirely is also fine; the worktrees will branch from the initial commit (Phase 4) instead.

## What this skill will NOT do

- Push anything to a remote (the project doesn't have a remote yet anyway).
- Install dependencies directly. `/define-architect` writes `WORKFLOW_WORKTREE_SETUP_CMD` into `.claude/workflow.config` in Phase 7, and `/add-worktree` runs it inside each new worktree in Phase 9 — so dependencies install once per worktree at creation, not by this skill itself.
- Run the project-definition dialogs itself. CI, deployment artifacts, code scaffold, test scaffold, and ticketing wiring are all owned by `/define-project` (invoked in Phase 7), not this skill.
- Re-run safely. **This is a one-time bootstrap.** Running it again on an already-initialized project will reset `.git/` and lose your history. Refuse if `docs/` already exists and doesn't look like the example template.

## Companion skills

- **`add-worktree`** / **`remove-worktree`** / **`list-worktrees`** — worktree CRUD.
- **`todo`** — the day-to-day workflow this skill bootstraps the user into.
- **`base-push`** / **`base-merge`** / **`base-pr`** / **`base-test`** — the underlying local-first branch flow (origin is write-only via `base-push`; there is no pull skill).
- **`agent-send`** / **`agent-msg`** / **`agent-broadcast`** / **`agent-rename`** — agent-to-agent comms between the spawned panes.
