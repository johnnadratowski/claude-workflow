# claude-workflow

A drop-in `.claude/` for Claude Code projects that adds:

- **Inter-agent communication** — Claude sessions in different tmux panes can message each other (`/agent-send`, `/agent-msg`, `/agent-broadcast`, `/agent-rename`), with **at-least-once delivery**: every message is staged in a durable per-recipient mailbox and re-injected by a `Stop`-hook drain if the live nudge is missed.
- **Fleet orchestration** — `/agent-fanout` shows fleet status, fans messages out by role, and can idle-gated force-restart agents (`claude --resume`, always confirmed first).
- **Local-first base-branch workflow** — `/base-push`, `/base-merge`, `/base-pr`, `/base-test`. All worktrees share one `.git`, so the local `<base>` ref is the single coordination point; merge/test/review operate on local refs and never touch the network. **`/base-push` is the only skill that pushes `origin/<base>`** (it publishes local `<base>`); the PR lifecycle skills `/open-pr`/`/pr-comments` make their own deliberate, user-gated origin writes (`pr/*` branches, comment posts) — never the base. For the base, origin is write-only — there is no pull skill. The base branch is never checked out in a persistent worktree; promotions go through a short-lived transient worktree.
- **Auto-registration + role hooks** — Claude sessions register themselves at startup with their git branch as the agent name (rename anytime with `/agent-rename`), and get **agent-type-specific startup instructions** injected from `.claude/agent-roles/<role>.md` (coordinator / review / feature / test, derived from the name).
- **Autonomous driver** — `/afk` carries a task to done unattended: implement → doc-sync → review loop → test loop → land, stopping only for genuinely blocking questions.

The base branch name is configurable per-project via `.claude/workflow.config`. Default is `main`.

## Quick start: use this repo as a project starter

The fastest path from "clean slate" to "running multi-agent workflow":

```bash
# 1. Clone this repo and rename it to your project
git clone https://example.com/your-fork-of-claude-workflow my-project
cd my-project

# 2. Start a Claude session inside a tmux pane
tmux new-session
claude

# 3. Run the initializer
> /base-initialize
```

`/base-initialize` will:

1. Ask for your project's name, description, base branch, and tech stack
2. Reset `.git/` and reinitialize (the workflow's history is irrelevant to your project)
3. Install the example docs from `templates/example_docs/` as your real `docs/` (you'll customize in the interview at the end)
4. Install the lightweight `CLAUDE.md` template, substituting your project metadata
5. Write `.claude/workflow.config` with your chosen base branch
6. Remove `templates/`, the workflow's `README.md`, and `workflow.config.example` — they're no longer needed
7. Ask how many feature / PR review / test agents you want
8. Create that many worktrees (each on its own branch)
9. Open a tmux pane (or window) for each, `cd` into it, and start `claude`
10. Interview you about the project and fill in `docs/architecture.md`, `docs/best-practices.md`, `docs/security.md`, `docs/testing.md`

After this you have: a fresh project repo, a running fleet (one agent per worktree, each in its own tmux window with a full cell — brought up by `/fleet-layout boot` from the worktrees manifest, so you can `down` and `boot` it again any time, and add or remove agents later with `/add-worktree --agent` / `/remove-worktree`), and starting documentation. The doc-drift loop in `/todo` will grow `docs/best-practices.md` organically as you ship work.

Before running `/base-initialize`, make sure you've completed the install steps below (especially the user-level `SessionStart` hook in step 4) so the spawned agents auto-register.

## Prerequisites

- **Claude Code CLI** — this is a Claude Code skill package; it has no value without it.
- **tmux** — both the inter-agent communication mechanism (delivery via `tmux send-keys`) and the agent registration (tracks `$TMUX_PANE`) require tmux. Launch Claude sessions inside tmux panes. **A session started outside tmux silently no-ops the registration hook and cannot send or receive messages.**
- **bash 3.2+** — the scripts use `[[`, arrays, parameter expansion, etc. macOS' system bash works.
- **git** — required for branch detection, worktree management, and the entire base-branch workflow.
- **jq** (recommended) — the registration hook parses `session_id` from stdin JSON via `jq` for the most reliable PID discovery. Without it, it falls back to a process-tree walk (still works, slightly less robust).
- **uuidgen** — used by `agent-send.sh` to mint message IDs. Available out of the box on macOS and most Linux distros.

## Install

### 1. Copy the workflow into your project

```bash
cp -r /path/to/claude-workflow/.claude/. /path/to/your-project/.claude/
```

This puts hooks, scripts, and skills in your project. Make the shell scripts executable:

```bash
chmod +x /path/to/your-project/.claude/hooks/*.sh /path/to/your-project/.claude/scripts/*.sh
```

### 2. Create the per-project config

```bash
cp workflow.config.example /path/to/your-project/.claude/workflow.config
$EDITOR /path/to/your-project/.claude/workflow.config
```

Set `WORKFLOW_BASE_BRANCH` to whatever your trunk is called (`main`, `master`, `trunk`, `develop`, etc.). Optionally set `WORKFLOW_MAIN_PATH` if your main clone lives somewhere different from where you're running the skills.

### 3. Merge the project-level settings.json

The project-level hooks — `UserPromptSubmit` (mark-busy), `Stop` (drain-inbox), `SessionEnd` (unregister) — and the safety-rail deny rules go in your project's `.claude/settings.json`. See `.claude/settings.json.example` — copy the `hooks` blocks and the `permissions.deny` list into your existing settings (if any), or use the example as a starting point. (`/base-initialize` installs/merges these for you.)

If you want pushes of your branches to skip the Claude Code approval prompt, add entries to `permissions.allow`, e.g.:

```json
"allow": [
  "Bash(git push origin main)",
  "Bash(git push origin feature/*)"
]
```

### 4. Install the SessionStart hook at user-level

**This step is required** — without it, Claude sessions won't auto-register and `/agent-send` / `/agent-msg` won't find peers.

`SessionStart` hooks fire BEFORE project settings are loaded, so they can't live in a project's `.claude/settings.json` — Claude Code silently rejects them there (visible via `/hooks`: the category shows but the entry is missing). They have to go in **user-level** `~/.claude/settings.json`.

Open `~/.claude/settings.json` (create it if missing) and merge in the `hooks.SessionStart` block from `.claude/settings-user-level.json.example`. The command is intentionally generic: it walks up to the git toplevel from wherever Claude was launched, and only runs the hook if that toplevel has a `.claude/hooks/register-agent.sh`. So installing it once at user level makes it a no-op in every project that doesn't ship this workflow, and active in every project that does.

If you already have a `hooks.SessionStart` array there, append a new entry rather than replacing.

### 5. Verify

Start a new `claude` session **inside a tmux pane**, in your project's directory. Check:

```bash
tail ~/.claude/debug/register-agent.log
```

You should see a `[sessionstart] fired` line with your PID and branch name. The agent name will be your current git branch (sanitized: slashes → dashes).

Then check the registry:

```bash
ls ~/.claude/running-agents/
```

You should see `<your-branch>.<claude-pid>` listed.

To test inter-agent comms, open a SECOND tmux pane and start another `claude` in a different worktree. Then from either session, ask Claude to use the `/agent-send` skill to message the other.

### 6. Register the `merge=ours` driver (per clone)

`docs/TODO.md` is a **generated artifact** that gets re-derived from `docs/todos/*.md`. The shipped `.gitattributes` marks it `merge=ours` so it never produces a textual merge conflict — the base-* merge paths regenerate it after the merge instead. But **`merge=ours` is inert until the driver is registered locally**: git refuses to auto-run a committed merge driver (code-exec safety), so each clone must opt in once:

```bash
.claude/scripts/setup-git-merge-drivers.sh   # runs `git config merge.ours.driver true`
```

Run it **once per clone** (the config lives in the shared `.git` common dir, so it also covers every worktree). The idiomatic way to make it automatic is to wire it into your project's own install/postinstall step — e.g. a `package.json` `prepare` script that runs `./.claude/scripts/setup-git-merge-drivers.sh`, or an equivalent hook for your toolchain — so a fresh clone registers the driver on first install.

Until it's registered, merges fall back to a normal (possibly-conflicting) merge of `docs/TODO.md` — safe, not silently wrong, but you lose the no-conflict guarantee.

## Troubleshooting

- **No log entries in `~/.claude/debug/register-agent.log`** — the SessionStart hook isn't firing. Check `/hooks` from inside a Claude session; if "SessionStart" shows no entries, the hook isn't loading. Verify (a) it's in **user-level** `~/.claude/settings.json`, not the project one; (b) the JSON parses (`jq . ~/.claude/settings.json`).
- **`agent-send` fails with "no agent named X"** — the target session isn't registered. Either the hook didn't fire for it, or it crashed without `SessionEnd` cleaning up. Have the target session run any `agent-*` command to force a self-heal, or restart the claude session.
- **`agent-send` fails with "agent X (pid N) is gone — pruned stale registry entry"** — the registry entry was stale. Self-heal-on-send pruned it. The target session probably has a new PID; have it run any `agent-*` command to re-register (or restart).
- **Hook fires but writes a wrong PID** — `register-agent.sh` walks the process tree to find the actual `claude` PID. If you see the wrong PID in the registry, your `claude` process command line doesn't start with `claude`; check `ps -p <pid> -o command=` and consider adjusting the regex in the script.

## What's in here

```
.claude/
├── hooks/
│   ├── register-agent.sh        Idempotent registration + role-context inject.
│   │                             SessionStart (user-level) + self-heal prelude.
│   ├── mark-busy.sh             UserPromptSubmit — marks the agent busy so peers
│   │                             skip a redundant nudge mid-turn.
│   ├── drain-inbox.sh           Stop — drains the per-recipient mailbox so a
│   │                             missed nudge is re-delivered (at-least-once).
│   ├── drain-inbox.test.sh      Hermetic test suite for the drain.
│   └── unregister-agent.sh      SessionEnd cleanup (registry + busy marker).
├── agent-roles/                 Startup instructions injected per agent type:
│   ├── coordinator.md            coordinator / review / feature / test. Edit to
│   ├── review.md                 change what each agent type is told. Role is
│   ├── feature.md                derived from the agent name (override via
│   └── test.md                   ~/.claude/agents/<name>.role).
├── scripts/
│   ├── _config.sh               Sourceable config loader.
│   ├── agent-send.sh            Backing script for /agent-send (req/rep/fwd).
│   ├── agent-broadcast.sh       Backing script for /agent-broadcast (fan-out).
│   ├── agent-fanout.sh          Backing script for /agent-fanout (status/merge-down/send/restart).
│   ├── agent-msg.sh             Backing script for /agent-msg (read+delete; or `drain` the mailbox).
│   ├── inbox-watcher.sh         Opt-in poller that re-nudges parked agents.
│   ├── agent-rename.sh          Backing script for /agent-rename.
│   ├── fleet-layout.sh          Backing script for /fleet-layout: retopologize the
│   │                             agents' tmux panes (single/dual/wide), (re)label + order
│   │                             windows, `boot` the fleet from cold, `down` it cleanly.
│   ├── workflow-local.sh        The single writer of .claude/workflow.config.local
│   │                             (`set` a machine-local knob, `seed` it into a worktree).
│   ├── setup-git-merge-drivers.sh  Registers the `merge.ours` driver per clone
│   │                             (`git config merge.ours.driver true`) so the
│   │                             `merge=ours` .gitattributes entries take effect.
│   │                             Run once per clone — see Install step 6.
│   └── gen-todos.mjs            Generates docs/TODO.md from docs/todos/ + validates.
├── skills/
│   ├── agent-msg/               Inbound-message handler (banner + branch).
│   ├── agent-send/              Send to a peer agent (--reply / --followup).
│   ├── agent-broadcast/         Fan one message out to all live peers.
│   ├── agent-fanout/            Fleet status + role-targeted fan-out + force-restart.
│   ├── agent-rename/            Rename this agent everywhere.
│   ├── base-push/               Land current branch into LOCAL <base>, then
│   │                             publish to origin (defines the
│   │                             merge_into_branch_local helper). Only origin touch.
│   ├── base-merge/              Local-only sync of <base> (down/up). No network.
│   ├── base-pr/                 In-place local-first review of what's new on
│   │                             <base>; promote fixes locally; re-anchor.
│   ├── base-test/               Merge local <base>, run all gates, report.
│   ├── todo/                    File-per-TODO lifecycle: add → plan → implement →
│   │                             doc-sync (incl. architecture) → review → close.
│   │                             Regenerates docs/TODO.md after every mutation.
│   ├── afk/                     Autonomous driver: implement → review → test → land.
│   ├── define-project/ +        Interactive project-definition orchestrator and
│   │   define-product/             its subskills (product → architect → QA →
│   │   define-architect/           deploy/security → TODO-taxonomy).
│   │   define-qa/
│   │   define-deploy/
│   │   define-tickets/          Tailors the TODO taxonomy (no external provider).
│   ├── feynman-auditor/ +       Language-agnostic deep-audit skills (used by
│   │   state-inconsistency-auditor/   /base-pr on high-risk diffs).
│   │   nemesis-auditor/
│   ├── add-worktree/            git worktree add wrapper + env-copy + setup.
│   ├── remove-worktree/         git worktree remove with confirmation.
│   ├── list-worktrees/          Annotated list of all worktrees.
│   └── base-initialize/         One-time bootstrap (reset .git, install docs +
│                                hooks, seed TODO index, create worktrees, run
│                                /define-project).
├── docs/                        Shared workflow docs (sync like any machinery file):
│   ├── fleet-base-workflow.md   Base-branch model + merge-helper contract.
│   ├── inter-agent-comms.md     Protocol writeup for the comms layer.
│   └── todo-system-internals.md TODO-system internals (cross-links, ID allocation).
├── settings.json.example        Project-level (deny + mark-busy/drain/unregister).
└── settings-user-level.json.example   SessionStart hook for ~/.claude/.

workflow.config.example          Sample config file.

templates/
├── CLAUDE.md                    Lightweight CLAUDE.md template; links to docs/.
└── example_docs/                Project-doc structure to copy as your docs/.
    │                            Each file ships with EXAMPLE content (not
    │                            TODO placeholders) demonstrating the format.
    ├── README.md                Format + how the workflow uses each file.
    ├── best-practices.md        Scenario + rule conventions (3 worked examples).
    ├── architecture.md          Components + invariants (task-tracker example).
    ├── security.md              Threat model + sensitive-op rules (web-app example).
    ├── testing.md               Test categories + when to add tests.
    ├── api-conventions.md       REST API conventions (delete if no API surface).
    ├── api.md                   Rendered API reference (delete if no API surface).
    └── todos/                   milestones.json taxonomy + README (the TODO model).

docs/
└── integration-notes.md         C-13 integration-notes template (copied into the
                                 consuming project's docs/).
```

## Skills reference

| Skill | What it does |
|---|---|
| **`/base-push`** | Land the current feature branch into LOCAL `$WORKFLOW_BASE_BRANCH` via a transient worktree, then publish local `<base>` to origin. **The only skill that pushes `origin/<base>`.** Defines `merge_into_branch_local` (the local-only helper the other base-* skills call). `--no-publish` skips the push (= `/base-merge up`). |
| **`/base-merge`** | Local-only sync (no fetch, no push). `down` (merge local `<base>` into current), `up` (advance local `<base>` from current), or both. Reports the local-vs-origin drift so unpublished work is never invisible. |
| **`/base-pr`** | In-place, local-first PR review: the current branch is a baseline snapshot; diffs it against local `<base>` and audits the new commits (design / security / **doc-drift incl. architecture**), escalating to the nemesis deep-audit on high-risk diffs. Optionally applies fixes and promotes them into local `<base>`, then re-anchors the snapshot. No fetch, no push. |
| **`/base-test`** | Merge LOCAL `$WORKFLOW_BASE_BRANCH` into the current branch, then run every project quality gate against the merged result. Operates in place — no sandbox, no commit, no push. Reports failures together (doesn't stop at the first). |
| **`/open-pr`** | Open a GitHub PR on a dedicated **frozen `pr/*` branch** rooted at `$WORKFLOW_PR_TARGET_BRANCH` (default: the repo's default branch) — never the live base. Scoped from the TODO ledger's `commits:` (merge SHAs force a path-based split) or `--snapshot <ref>` for a whole-batch PR. Gates run on the PR branch standing alone; `gh pr create` is **user-gated**; `--absorb <n>` merges the merged PR back into the local base (never pushes `origin/<base>`). Owns TODO↔PR tagging + the `pr:` frontmatter back-pointer. |
| **`/pr-comments <n>`** | Service a PR review round methodically: paginated inventory across all three comment surfaces (+ GraphQL thread resolved-state), investigate-before-believing (evidence-backed refutation is a first-class disposition), clustered triage with the user while reply drafts stay UNPOSTED, fixes through the internal review flow with TODO reopen/update linkage, a peer package-audit, then **atomic posting only on the user's final approval**. |
| **`/agent-send <target> "<body>" [--reply\|--followup]`** | Send a message to another Claude session on this machine. Self-heals the registry, stages the body in a durable per-recipient mailbox, then nudges via `tmux send-keys` (skipped if the target is busy / scrolled — the drain delivers instead). `--reply` = terminal (no response); `--followup` = threaded message expecting a response. |
| **`/agent-msg <sender> <filename> [reply\|followup]`** | Inbound-message handler. Invoked AUTOMATICALLY when a peer's `tmux send-keys` (or the Stop-hook drain) lands `/agent-msg ...` in your prompt. Reads + deletes the file, prints a visible banner, then processes (request/followup) or integrates (reply). You never type this yourself. |
| **`/agent-broadcast --stdin <<'BODY'…`** | Fan one message out to ALL live peers (`--exclude`, `--followup`, `--dry-run`). Reuses `/agent-send` per recipient. High blast-radius — requires explicit user authorization. |
| **`/agent-fanout <status\|msg\|merge-down\|restart>`** | Fleet orchestration: read-only `status` snapshot (roles/busy/branch), role-targeted message fan-out, canned post-`/base-push` `merge-down` sync, and idle-gated `restart` (kill the pane's claude, relaunch `claude --resume` to preserve context). Messages need explicit authorization; restarts always confirm first. |
| **`/agent-rename <new-name>`** | Rename this agent everywhere: registry file in `~/.claude/running-agents/`, persistent base-branch file in `~/.claude/agents/`, tmux pane title, tmux window name, Claude session label (via the built-in `/rename`), and the local git branch (`git branch -m`). |
| **`/todo <verb-or-text>`** | File-per-TODO lifecycle manager. `add` mints a stable `AREA-<NS>-<lane>NNN` ID (per-engineer `<NS>` + per-worktree `<lane>` = collision-free across clones AND parallel worktrees) and writes `docs/todos/<ID>.md`; the spine is add → plan → implement → **doc-sync (incl. architecture)** → review → `continue` (promote + notify tester) → close (archive to `completed/`). Regenerates `docs/TODO.md` + validates frontmatter after every mutation. The TODO files are the tracker — no external ticket system. |
| **`/afk --pr <agent> [--test <agent>]`** | Autonomous driver. Carries the current task to done unattended: implement → doc-sync → review loop (with a peer reviewer, failover) → test loop → land into local `<base>` (publish if clean). Stops and notifies only for genuinely blocking questions or non-converging loops. |
| **`/define-project`** (+ `define-product` / `define-architect` / `define-qa` / `define-deploy` / `define-tickets`) | Interactive project-definition orchestrator. Drives product → architecture → QA → deploy/security → TODO-taxonomy dialogs, each with subagent critical review + signoff, populating `docs/` and scaffolding code/tests/CI. Run by `/base-initialize`; re-enterable later. |
| **`/add-worktree <name>`** | Create a new git worktree at `<parent>/<repo>-<name>`. Optionally on a new branch (default), an existing branch (`--branch <name>`), or from a non-default ref (`--from <ref>`). Optionally copies env files (`WORKFLOW_WORKTREE_COPY_FILES`) and runs a setup command (`WORKFLOW_WORKTREE_SETUP_CMD`) from config. |
| **`/remove-worktree <name>`** | Tear down a worktree. Confirms first (unless `--force`). `--delete-branch` also removes the local branch. Refuses if the worktree has uncommitted changes (override with `--force`). |
| **`/list-worktrees`** | Show all worktrees of the current repo: path, branch, last commit, dirty status, and a `(current)` marker for the one you're calling from. |
| **`/base-initialize`** | **Run once, at project start.** Bootstraps a fresh project from a `claude-workflow` clone: resets `.git/`, installs `docs/` from `templates/example_docs/`, installs `CLAUDE.md`, writes `.claude/workflow.config`, removes the now-redundant templates and workflow README, asks how many feature/PR/test agents you want, creates that many worktrees, opens tmux panes for each, starts `claude` in each, then interviews you about the project to fill in the docs. See the Quick start above. |

### Deep-audit skills (third-party, bundled as-is)

These are language-agnostic deep-audit skills wired into `/base-pr`'s step 6 when the diff touches a high-risk surface. They predate `claude-workflow` and ship as authored (Solidity examples remain; the techniques themselves apply to any language).

| Skill | What it does |
|---|---|
| **`/nemesis-auditor`** | Entry point. Runs `feynman-auditor` (deep logic bug finder) and `state-inconsistency-auditor` (coupled-state bug finder) as primary passes, then fuses their outputs in a feedback loop to find bugs at the intersection. Writes verified findings to disk. Designed to be scoped to a specific diff or changed-file set, not the whole repo. |
| **`/feynman-auditor`** | Stand-alone deep logic-bug finder using the Feynman technique. Questions every line, ordering, guard presence/absence, and implicit assumption. Used as Stage 1 by `nemesis-auditor`. |
| **`/state-inconsistency-auditor`** | Finds bugs where an operation mutates one piece of coupled state without updating its dependent counterpart. Used as Stage 2 by `nemesis-auditor`. |

## Practical examples

### Multi-agent PR review

Open two tmux panes, start a `claude` session in each (in different worktrees of the same repo). Agent A is the implementer; Agent B is the reviewer.

```text
Pane A (worktree on feat/foo)              Pane B (worktree on review-sandbox)
─────────────────────────────────────      ─────────────────────────────────────
$ claude
agent-A> <implements a feature, commits>
agent-A> /base-test                         (runs all gates locally)
agent-A> /agent-send review-sandbox \
        "Please /base-pr review my work
         on feat/foo. Push back any
         findings via --reply."

                                            agent-B receives /agent-msg, banner
                                            shows the request, processes it.
                                            agent-B> /base-pr --base feat/foo
                                            (runs the review against feat/foo
                                             in the sandbox, consulting
                                             docs/best-practices.md, etc.)
                                            agent-B> /agent-send feat-foo \
                                                    "Found 3 issues:
                                                     1. ...
                                                     2. ...
                                                     3. ..." --reply

agent-A receives the reply, banner
shows "REPLY from review-sandbox",
addresses each finding, commits, then:
agent-A> /agent-send review-sandbox \
        "Re-review please; addressed
         all 3 findings."
                                            <iterate>

agent-A> /base-push  (once review-sandbox approves)
```

This pattern keeps the implementer and reviewer in separate contexts, prevents the implementer's bias from colouring the review, and naturally records the review trail in the conversation transcripts on both sides.

### Dispatching a sub-task

```text
You> /agent-send researcher \
     "Find every file that calls deprecated function X.
      Reply with a list of file:line locations."

         (researcher agent, in a different worktree,
          gets the request, grep-walks the codebase,
          replies via --reply with a numbered list)

You receive the reply, decide what to do with it.
```

Useful when you want a context-window-isolated sub-task to run in parallel with your main work.

### Aligning multiple worktrees after a base advance

```text
Coordination is purely local — once one worktree advances local <base>
(via /base-push or /base-merge up), every other worktree shares the same
.git, so the new commits are already visible. To fold them into a peer's
feature branch, the peer runs /base-merge down. Broadcast the nudge once:

You> /agent-broadcast --stdin <<'BODY'
local <base> just advanced. Please /base-merge down to pick it up.
BODY

   (each peer runs /base-merge down, replies with confirmation +
    any conflicts encountered)
```

No fetch needed — the refs are local. `/agent-broadcast` saves you switching panes.

## Project documentation structure

The workflow skills (especially `/base-pr` and `/base-test`) work best when the project ships a small, scenario-shaped docs tree. The `templates/example_docs/` directory in this repo is a starter you can copy into your project as `docs/`. **Each file is filled in with real-looking example content**, not TODO placeholders — read the examples to internalize the format before replacing them with your own.

```bash
cp -r /path/to/claude-workflow/templates/example_docs /path/to/your-project/docs
cp /path/to/claude-workflow/templates/CLAUDE.md /path/to/your-project/CLAUDE.md
```

The template encodes one strong convention: **docs are scenario + rule + how-to-apply, not topic + paragraph**. A scenario describes a real bug or near-miss; a rule distills the lesson in one imperative sentence; a how-to-apply line tells future readers when the rule kicks in. Scenarios are load-bearing — they survive refactors that would otherwise let topic-shaped docs rot.

`CLAUDE.md` is intentionally light — a one-paragraph intro, links to each `docs/*.md`, and a handful of hard rules. The detailed material lives in `docs/`, where it doesn't bloat every session's context window.

See `templates/example_docs/README.md` for the format spec and how each skill uses each file.

## Configuration

All per-project configuration lives in **`.claude/workflow.config`** — a shell file sourced by `.claude/scripts/_config.sh`. Copy `workflow.config.example` to start. Every variable is optional; defaults preserve current behavior. Override any variable per-invocation by setting it in your shell environment before running a skill.

### Base-branch workflow

| Variable | Default | Purpose |
|---|---|---|
| `WORKFLOW_BASE_BRANCH` | `main` | The shared "trunk" branch other branches merge into. Lives only as a ref (never checked out in a persistent worktree). Used by `/base-push`, `/base-merge`, `/base-pr`, `/base-test`. |
| `WORKFLOW_MAIN_PATH` | git toplevel of cwd | Path to the canonical clone, used as the anchor for transient worktrees created during `/base-push` and `/base-pr` promotions. Only override if your "main clone" lives somewhere different from where you call skills. |

### Agent workflow

| Variable | Default | Purpose |
|---|---|---|
| `WORKFLOW_AGENT_DEFAULT_BRANCH` | (unset) | Pin an agent's identity in config. When set: (a) fresh sessions register under this name (overriding current git branch); (b) the recorded base branch is forced to this value — so the wrong-branch warning fires immediately if the worktree isn't on it. Sanitized the same way as branch names (`/` → `-`). |
| `WORKFLOW_AGENT_NAME_PREFIX` | (unset) | Prepended to every auto-derived agent name. E.g. `"frontend-"` → agent becomes `frontend-main`. Applied after the transform/sanitization. |
| `WORKFLOW_AGENT_NAME_TRANSFORM` | (unset) | Sed expression applied to the derived name BEFORE sanitization. E.g. `"s\|^feature/\|\|"` strips a `feature/` prefix from the branch name. |
| `WORKFLOW_AGENT_SKIP_RENAME` | (unset = false) | Set to `"1"` to skip the `/rename` keystroke that SessionStart fires into the prompt. (The keystroke updates Claude's own session label to match the agent name. Some users find it intrusive.) |
| `WORKFLOW_AGENT_SKIP_BRANCH_WARN` | (unset = false) | Set to `"1"` to suppress the "you're on the wrong branch" warning the SessionStart hook emits when the worktree's branch differs from the recorded base. Useful in single-branch projects. |

### Agent-name precedence

The hook decides the agent name in this order — first non-empty wins, then the result is transformed/prefixed/sanitized:

1. **Session file's `name` field** (set by `/rename` or `/agent-rename`; persists across `--resume`) — most specific
2. **`WORKFLOW_AGENT_DEFAULT_BRANCH`** — config-level pin
3. **Current git branch** — auto-derived
4. **cwd basename** — last resort

So a config default acts as the *starting* identity but a later `/agent-rename` overrides it via the session file. To revert to the config default, clear the session name (e.g. by starting a fresh session not via `--resume`).

### Where each variable is read

| Variable | Read by |
|---|---|
| `WORKFLOW_BASE_BRANCH` | `base-push`, `base-merge`, `base-pr`, `base-test` |
| `WORKFLOW_MAIN_PATH` | `merge_into_branch_local` helper inside `base-push` |
| `WORKFLOW_AGENT_*` | `register-agent.sh` only (via `_config.sh`) |
| `WORKFLOW_TESTING_AGENT` | `todo` (`continue`), `afk` |
| `WORKFLOW_TODO_LANE` | `todo` (ID allocation — per-worktree lane) |
| `WORKFLOW_TODO_NS` | `_config.sh`, `todo` (ID allocation — per-engineer namespace; set per-clone in `.claude/workflow.config.local`) |
| `AGENT_INBOX_GC_DAYS` | `drain-inbox.sh` |

## Caveats

- **macOS / Linux only** — the scripts use `tmux`, `ps`, `jq`, `git`, and bash arrays. `jq` is a soft dependency for `register-agent.sh` (the session-id lookup degrades to process-tree walk without it).
- **tmux required** — the registry and message-delivery mechanism both rely on `tmux send-keys`. The hook silently no-ops when `$TMUX_PANE` is unset.
- **The base branch must not be checked out in any persistent worktree.** The `merge_into_branch_local` helper checks it out as a branch (not detached) in a transient worktree, so a concurrent checkout elsewhere will make the helper fail — silently breaking promotion for every agent. By design, the base branch only exists as a ref and only materializes briefly during a `/base-push`, `/base-merge up`, or `/base-pr` promotion. For a base-tracking worktree, ride a stable branch or a detached `origin/<base>`.

## Adapting

- `base-pr` ships with a TODO marker for gates — fill in your project's lint/typecheck/test commands.
- `settings.json.example` ships with `permissions.allow` covering `git checkout` (branch switches; `git checkout --` file-discard stays denied) and the inter-agent backing scripts (`agent-send`/`broadcast`/`fanout`/`msg`) so fleet fan-outs and inbox draining don't prompt per command. Add `Bash(git push origin <pattern>)` entries for the branch names your skills will push.
- If you want a different agent-name scheme (not the git branch), edit `register-agent.sh`'s "Determine agent name" section — the fallback chain is session-file `name` → git branch → cwd basename.
