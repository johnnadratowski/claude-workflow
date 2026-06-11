# Agent workflow (`.claude/`)

This directory is the **multi-agent workflow** this project runs on — a set of Claude Code
**skills**, **hooks**, and **scripts** for coordinating several Claude sessions (one per git
worktree) on the same machine. It's installed from the reusable
[`claude-workflow`](https://example.com/your-fork-of-claude-workflow) template and ships with
your project, so this file stays as the in-repo reference. (The base branch name is
configurable — `WORKFLOW_BASE_BRANCH` in `.claude/workflow.config`, default `main`; this doc
writes it as `<base>`.)

> The short version: each agent is a Claude session in its own tmux pane + git worktree. They
> share one local `<base>` branch as the coordination point, message each other through a
> durable mailbox, and track work as one-file-per-TODO. Only `/base-push` touches `origin`.

## The model in one screen

- **Worktrees + agents.** Every agent is a `claude` session in a tmux pane, in its own git
  worktree (`<repo>-<name>`). It auto-registers at `SessionStart` and gets **role-specific
  startup instructions** based on its name.
- **Roles** (derived from the agent name; override via `~/.claude/agents/<name>.role`):
  - **feature** — implements TODOs end-to-end (the default).
  - **review** (`*-pr` / `*-review`) — runs `/base-pr` audits, replies GREEN or findings.
  - **test** (`*-test`) — runs `/base-test` gate sweeps, replies PASS or failures.
  - **coordinator** (`cc` / `*-cc` / `coordinator`) — acts for the user; rides a dedicated
    `<base>-cc` branch and can also do feature work on it (see `agent-roles/coordinator.md`).
- **Local-first branching.** All worktrees share one `.git`, so **local `refs/heads/<base>`**
  is the single coordination ref every agent reads and advances — a peer's work is mergeable
  the moment it's *committed*. `origin/<base>` advances **only** when someone runs `/base-push`;
  there is no pull skill (origin is write-only). **Never check out the literal base branch** in
  a worktree (it breaks the transient-merge machinery for everyone).
- **Messaging.** Agents message each other via a durable **per-recipient mailbox**
  (`~/.claude/agent-inbox/<recipient>/`) plus a best-effort tmux nudge; a `Stop`-hook drain
  re-injects anything the nudge missed, so delivery is **at-least-once**.
- **Work tracking.** Every substantive unit of work is one file under `docs/todos/<ID>.md`;
  `docs/TODO.md` is the **generated** index. Run substantive work through `/todo`.
- **Docs are load-bearing.** The `define-*` skills author the doc structure; `/todo` and
  `/base-pr` keep it in sync (including `docs/architecture.md`) before/at review.

## Skills

### Git workflow (local-first)
| Skill | What it does |
|---|---|
| `/base-push` | Land the current branch into **local** `<base>`, then publish to `origin`. The **only** skill that touches origin. Defines the `merge_into_branch_local` helper. |
| `/base-merge` | Local-only sync of `<base>` ↔ the current branch (`down`/`up`); no network. |
| `/base-pr` | In-place PR-style review of what's new on local `<base>` (design / security / **doc-drift incl. architecture**); optionally apply fixes + promote locally. `--pr <n>` instead reviews a **GitHub PR** read-only and reports findings in the terminal (via `gh`, no posting). |
| `/base-test` | Merge local `<base>` into the current branch, run every project gate. Reports; no push. |

### Inter-agent comms → [`../docs/inter-agent-comms.md`](../docs/inter-agent-comms.md)
| Skill | What it does |
|---|---|
| `/agent-send` | Message a peer (`--reply` / `--followup`; `--stdin` heredoc preferred). |
| `/agent-msg` | Receiver-side handler (banner + req/rep/fwd). Auto-invoked; backed by `agent-msg.sh` (`drain` consumes the whole mailbox). |
| `/agent-broadcast` | Fan one message out to ALL live peers (explicit-authorization gate). |
| `/agent-fanout` | Fleet orchestration: `status`, role-targeted fan-out, canned `merge-down`, idle-gated `restart` (`claude --continue`). Backed by `agent-fanout.sh`. |
| `/agent-rename` | Rename this agent everywhere (registry + tmux + Claude session + git branch). |

### Work + autonomy
| Skill | What it does |
|---|---|
| `/todo` | File-per-TODO lifecycle. Mints `AREA-<lane>NNN` IDs (`WORKFLOW_TODO_LANE`), regenerates `docs/TODO.md` via `scripts/gen-todos.mjs`. Complex plans pass a peer **plan-review gate** (`PLAN GREEN` → `plan_review:` frontmatter), then user sign-off on the gate's deltas, before implementation; the human is the terminal reviewer of every loop. |
| `/afk` | Drive a task to done unattended: implement → doc-sync → review loop → test loop → land. Stops only for blocking questions. |

### Setup + project definition
| Skill | What it does |
|---|---|
| `/base-initialize` | One-time bootstrap: reset `.git`, install docs + hooks, seed the TODO index, create worktrees, run `/define-project`. |
| `/define-project` (+ `define-product`/`-architect`/`-qa`/`-deploy`/`-tickets`) | Interactive product → architecture → QA → deploy/security → TODO-taxonomy dialogs that populate `docs/` + scaffold code/tests/CI. |
| `/update-workflow` | Sync machinery updates (skills/hooks/scripts) **from** the upstream `claude-workflow` clone into this repo, preserving project-owned files. |

### Worktrees
`/add-worktree` · `/remove-worktree` · `/list-worktrees`. The coordinator worktree rides a
dedicated `<base>-cc` branch (`/add-worktree cc --branch <base>-cc --from origin/<base>`).

### Deep audit (language-agnostic) — escalated by `/base-pr` on high-risk diffs
`/feynman-auditor` · `/state-inconsistency-auditor` · `/nemesis-auditor`.

## Hooks (`hooks/`)
| Hook | Event | Role |
|---|---|---|
| `register-agent.sh` | SessionStart (+ self-heal) | Registers the agent, derives name + role, injects role context. Wired in **user-level** `~/.claude/settings.json` (SessionStart fires before project settings load). |
| `mark-busy.sh` | UserPromptSubmit | Marks the agent busy so peers skip a redundant nudge mid-turn. |
| `drain-inbox.sh` (+ `.test.sh`) | Stop | Re-injects undelivered mailbox messages (at-least-once); GCs abandoned mail; clears the busy marker. |
| `unregister-agent.sh` | SessionEnd | Cleans up the registry entry + busy marker. |

## Scripts (`scripts/`)
`_config.sh` (config loader) · `agent-send.sh` · `agent-broadcast.sh` · `agent-fanout.sh` ·
`agent-msg.sh` · `inbox-watcher.sh` (opt-in re-nudge daemon) · `agent-rename.sh` ·
`gen-todos.mjs` (TODO index generator/validator). The `agent-*` scripts are allow-listed in
`settings.json.example` so fan-outs/inbox-drains don't prompt; `agent-fanout.sh restart` still
requires `--yes` after confirmation.

## Install / configuration
See the project root README (or the template's) for the install checklist. Key files:
- `settings.json.example` → your project `.claude/settings.json` (deny rails + the Stop /
  UserPromptSubmit / SessionEnd hooks + the allow-list).
- `settings-user-level.json.example` → your `~/.claude/settings.json` (the SessionStart hook —
  **required**, agents won't auto-register without it).
- `workflow.config.example` → `.claude/workflow.config` (`WORKFLOW_*` knobs).

## Where to read more
- [`../docs/inter-agent-comms.md`](../docs/inter-agent-comms.md) — full messaging + registration protocol.
- [`agent-roles/`](agent-roles/) — per-role startup instructions injected at SessionStart.
- Each skill's own `SKILL.md` under `skills/<name>/` — the authoritative, detailed spec.
