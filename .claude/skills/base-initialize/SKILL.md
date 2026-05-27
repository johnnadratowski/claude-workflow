---
name: base-initialize
description: Bootstrap a new project from a `claude-workflow` clone. Runs once at project start. Resets `.git` (the workflow's history is irrelevant to the new project), installs `docs/` from `templates/example_docs`, installs `CLAUDE.md` from the template, writes `.claude/workflow.config`, asks how many feature / PR / test agents to spin up, creates that many worktrees, opens tmux panes for each, starts `claude` in each, then interviews the user to fill in `docs/best-practices.md` / `architecture.md` / `security.md` / `testing.md` with initial real content.
---

# base-initialize

**Run once, at the very start of a new project.**

Bootstraps a fresh project from a `claude-workflow` clone:

1. Resets git, installs the template docs + CLAUDE.md, writes the workflow config
2. Asks how many feature / PR / test agents to set up
3. Creates worktrees + opens tmux panes + starts `claude` in each
4. Interviews the user about the project, fills in the docs

After this skill finishes, the user has a working multi-agent setup with project-specific (not example) documentation.

## Pre-flight

Verify the cwd is a `claude-workflow` clone:

```bash
[ -d ./templates/example_docs ] && [ -d ./.claude/skills/base-pull ] \
  && [ -f ./workflow.config.example ] \
  || { echo "Doesn't look like a claude-workflow clone."; exit 1; }
```

Verify the user is inside `tmux` (we'll need to spawn panes):

```bash
[ -n "${TMUX:-}" ] || { echo "Run me from inside a tmux session — I'll spawn panes for each agent."; exit 1; }
```

## Phase 1: Project metadata

Use `AskUserQuestion` to collect, in this order:

| Field | Default | Notes |
|---|---|---|
| Project name | `basename $(pwd)` | Becomes the H1 in CLAUDE.md; also the prefix for worktree directory names. |
| Description | `(empty)` | One-paragraph; goes into CLAUDE.md after the heading. |
| Base branch | `main` | Becomes `WORKFLOW_BASE_BRANCH`. |
| Tech stack | — | Free-form one-line answer: language(s) + framework(s) + project shape (e.g. "TypeScript backend + React frontend", "Python CLI", "Rust library", "Go service"). Used as a hint for the setup-command guess below AND informs the docs interview later. |
| Setup command | inferred from stack | "What command installs dependencies?" Suggest one based on the tech stack (see mapping below). User can accept the suggestion, type their own, or say "none" if the project has no dependency-install step. Becomes `WORKFLOW_WORKTREE_SETUP_CMD`. |
| Env files to copy per worktree | `(none)` | "Are there any env-shaped files (`.env`, `.env.local`, `.envrc`, etc.) you want copied into each new worktree at creation? They're typically gitignored but each worktree needs its own copy." Comma-separated list, or blank for none. Becomes `WORKFLOW_WORKTREE_COPY_FILES`. Skip the question entirely if the user's stack obviously doesn't have env files (e.g. a pure CLI tool). |
| Git remote URL | `(none)` | "Do you have a remote you want to push to?" If yes, captured as a URL string and applied in Phase 2 via `git remote add origin <url>`. If no, skip — the user can add a remote later. |

### Setup command guessing

When asking for the setup command, use the tech-stack answer to suggest a sensible default. Show the suggestion in the question so the user can hit Enter to accept. If they say "I don't know", offer the suggestion explicitly and explain what it does.

| If the stack mentions … | Suggest |
|---|---|
| pnpm, or TypeScript/JavaScript without a clear package manager | `pnpm install --frozen-lockfile` |
| npm specifically | `npm ci` |
| yarn specifically | `yarn install --frozen-lockfile` |
| bun | `bun install --frozen-lockfile` |
| Python + poetry | `poetry install --no-root` |
| Python + uv | `uv sync` |
| Python + pip / requirements.txt | `pip install -r requirements.txt` |
| Python + pipenv | `pipenv install --deploy` |
| Rust / Cargo | `cargo fetch` |
| Go | `go mod download` |
| Ruby | `bundle install --frozen` |
| Java / Maven | `mvn install -DskipTests` |
| Java / Gradle | `./gradlew build -x test` |
| Elixir / Mix | `mix deps.get` |
| Haskell / Cabal | `cabal build --dependencies-only` |
| Swift Package Manager | `swift package resolve` |
| PHP / Composer | `composer install --no-dev` |
| C++ / CMake | `cmake -S . -B build && cmake --build build --target deps` (often project-specific; ask the user to override) |
| Unknown / mixed | leave blank; ask the user to fill it in later |

If the user explicitly answers "none" or leaves it blank: don't set `WORKFLOW_WORKTREE_SETUP_CMD` — the line stays commented in the config and `/add-worktree` runs no setup. The user can edit `.claude/workflow.config` later.

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

# Workflow config
cp workflow.config.example .claude/workflow.config

# Set the base branch
sed -i.bak "s|WORKFLOW_BASE_BRANCH=\"main\"|WORKFLOW_BASE_BRANCH=\"$BASE_BRANCH\"|" .claude/workflow.config

# Set the setup command if the user provided one (or accepted a guess).
# The template ships the line commented as a hint; uncomment + replace.
if [ -n "$SETUP_CMD" ]; then
  sed -i.bak "s|^# WORKFLOW_WORKTREE_SETUP_CMD=.*|WORKFLOW_WORKTREE_SETUP_CMD=\"$SETUP_CMD\"|" .claude/workflow.config
fi

# Set the env-files-to-copy list if the user named any.
# Convert the comma-separated answer into a shell array literal.
if [ -n "$COPY_FILES_LIST" ]; then
  copy_files_array=$(printf '%s' "$COPY_FILES_LIST" | awk -F, '{
    out=""; for (i=1;i<=NF;i++) { gsub(/^ +| +$/, "", $i); out = out (i>1?" ":"") "\"" $i "\""; } print out
  }')
  sed -i.bak "s|^# WORKFLOW_WORKTREE_COPY_FILES=.*|WORKFLOW_WORKTREE_COPY_FILES=($copy_files_array)|" .claude/workflow.config
fi

rm -f .claude/workflow.config.bak

# Remove now-redundant template files
rm -rf templates/
rm workflow.config.example
rm -f README.md   # original was the workflow's README; user will write their own
```

(macOS `sed -i ''` vs GNU `sed -i` differ — use `-i.bak` + `rm *.bak` pattern as a portable middle ground.)

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

Total worktrees = sum of the three counts. If 0, skip phase 6+ entirely (user can run `/add-worktree` later).

**Auto-derive the testing agent** from the answer. If `test count >= 1`, set `WORKFLOW_TESTING_AGENT="test-1"` so `/todo` Mode 4 dispatches there by default:

```bash
if [ "$TEST_COUNT" -ge 1 ]; then
  sed -i.bak "s|^# WORKFLOW_TESTING_AGENT=.*|WORKFLOW_TESTING_AGENT=\"test-1\"|" .claude/workflow.config
  rm -f .claude/workflow.config.bak
fi
```

This change isn't committed yet — it'll be picked up by the final commit in Phase 9 along with the docs-interview output. If the user creates zero test agents, `WORKFLOW_TESTING_AGENT` stays blank and `/todo continue` will ask the user for the target each time.

## Phase 6: Create worktrees

For each worktree name, invoke `/add-worktree <name>`:

- Path lands at `$(dirname $(pwd))/$(basename $(pwd))-<name>`
- Branch `<name>` is created from the current (just-initialized) base branch — the initial-commit SHA
- No `WORKFLOW_WORKTREE_SETUP_CMD` runs yet (the user hasn't configured it), so this is purely the `git worktree add`

If `WORKFLOW_WORKTREE_SETUP_CMD` was configured in Phase 3, each `/add-worktree` invocation will run it inside the new worktree — so dependencies get installed automatically as each worktree comes up. Streaming the install output to the user makes it visible; failures are surfaced but don't abort the worktree (it stays half-set-up so the user can debug).

After all worktrees are created, summarize the layout.

## Phase 7: Open tmux panes

For each worktree:

```bash
tmux new-window -n "$NAME" -c "$WORKTREE_PATH"
tmux send-keys -t "$NAME" "claude" Enter
```

Each new claude session auto-registers via the `SessionStart` hook (if you installed it at user level per the README). The agent name comes from its branch (i.e., the worktree name).

Alternative if the user prefers splits over windows: ask them via `AskUserQuestion` "New windows or splits?" before this phase.

## Phase 8: Documentation interview

The worktrees are up; the panes are running. Now drive an interview to replace the example content in `docs/` with project-specific content.

**Iterate over each doc in order.** For each, ask 2–4 targeted questions, draft the resulting content, show it to the user for approval, then write it.

### docs/architecture.md

- "What are the major components?" (list with one-line role each)
- "How does a typical request / operation flow through them?" (numbered list)
- "What's the most important invariant across components?" (one sentence + the reasoning)

Draft → confirm → write. Replace the example content entirely; the format spec at top of the file stays.

### docs/best-practices.md

- Open-ended: "What are the 2–3 most important coding conventions in this project? For each, what real or anticipated bug motivated it?"
- For each one: distill scenario + rule + how-to-apply. Confirm with user, write.

It's fine to land with just 2–3 rules — the doc-drift loop (run by `/todo` after each implementation) will grow it organically.

### docs/security.md

- "Does this project handle user data, secrets, authentication, or authorization?" If no → empty out security.md to just the format header; the doc-drift loop will populate it as relevant code lands.
- If yes → ask: "What are you protecting and from whom?" + "Name one or two security rules every contributor needs to know."

### docs/testing.md

- "What test categories does the project use?" (unit / integration / E2E / property / fuzz / etc.)
- "For each: where do tests live, what's the run command?"

Build the "Test categories" section from the answers. Add the gate-runner notes if the user has a CI matrix already.

### docs/api-conventions.md

- "Does this project expose an API surface (HTTP, RPC, library, CLI)?" If no → **delete** the file; tell the user it's gone.
- If yes → ask: shape, error format, versioning, naming.

### docs/TODO.md

- "Is there any work already queued up that should go in TODO.md?" Add as `##` headers.
- If nothing, leave the example template-strip in place so the user has a format example.

## Phase 9: Final commit

```bash
git add -A
git commit -m "docs: project-specific content from initialize interview"
```

## Phase 10: Report

Tell the user:

- Project initialized at `<path>`
- Branch: `<base-branch>`
- Worktrees created: list each path
- Agents started: list each pane / window name
- Docs populated: which docs were customized; which (if any) are still using the example content
- **Next step**: add your first todo with `/todo Add my first feature` (or similar), then `/todo do next`.
- **Workflow reminder**: the doc-drift loop (in `/todo`) will keep growing `docs/best-practices.md` as the project evolves — don't pre-fill it.

## Failure handling

- **Pre-flight fails** (not a claude-workflow clone, not in tmux): hard stop; explain.
- **User declines reset confirmation**: hard stop; no changes.
- **`git init` or any sed fails**: stop and report — the user's repo state could be partial; tell them which file to inspect.
- **`/add-worktree` fails for one or more worktrees**: continue with the rest; report which failed at the end. The user can re-run `/add-worktree` manually for the missed ones.
- **`tmux new-window` fails**: skip that pane; report. The user can `cd <worktree>` and `claude` manually.
- **Documentation interview can be skipped**: if the user says "skip docs interview" anywhere in phase 8, stop the interview, leave the example docs in place, and proceed to phase 9.

## What this skill will NOT do

- Push anything to a remote (the project doesn't have a remote yet anyway).
- Install dependencies directly. The setup command is captured in Phase 1, written into `.claude/workflow.config` in Phase 3, and run by `/add-worktree` in Phase 6 — so dependencies install once per worktree at creation, not by this skill itself.
- Set up CI, deployment, or any project infrastructure.
- Re-run safely. **This is a one-time bootstrap.** Running it again on an already-initialized project will reset `.git/` and lose your history. Refuse if `docs/` already exists and doesn't look like the example template.

## Companion skills

- **`add-worktree`** / **`remove-worktree`** / **`list-worktrees`** — worktree CRUD.
- **`todo`** — the day-to-day workflow this skill bootstraps the user into.
- **`base-pull`** / **`base-push`** / **`base-merge`** / **`base-pr`** / **`base-test`** — the underlying branch flow.
- **`agent-send`** / **`agent-msg`** / **`agent-rename`** — agent-to-agent comms between the spawned panes.
