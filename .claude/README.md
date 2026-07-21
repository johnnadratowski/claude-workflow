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
  - **coordinator** (`cc` / `*-cc` / `coordinator`) — acts for the user; rides a dedicated
    `<base>-cc` branch and can also do feature work on it (see `agent-roles/coordinator.md`).
  - Review and test are **not pane roles** anymore: every session spawns its own
    [`reviewer`](agents/reviewer.md) / [`tester`](agents/tester.md) **subagents** via the
    Agent tool (plans via the [`planner`](agents/planner.md) subagent). The name classifier
    still recognizes legacy `*-pr`/`*-test` names (window labels, fanout targeting), but no
    role files ship for them.
- **Local-first branching.** All worktrees share one `.git`, so **local `refs/heads/<base>`**
  is the single coordination ref every agent reads and advances — a peer's work is mergeable
  the moment it's *committed*. `origin/<base>` advances **only** when someone runs `/base-push`;
  there is no pull skill (origin is write-only). **Never check out the literal base branch** in
  a worktree (it breaks the transient-merge machinery for everyone).
- **Messaging.** Agents message each other via a durable **per-recipient mailbox**
  (`~/.claude/agent-inbox/<recipient>/`) plus a best-effort tmux nudge; a `Stop`-hook drain
  re-injects anything the nudge missed, so delivery is **at-least-once**.
- **tmux is optional.** Identity falls back to a cwd-based token when `$TMUX_PANE` is unset
  (one agent per worktree), so registration, self-id, mailbox delivery/drain, busy-marking
  and `status` work headless (`_fleet.sh`). tmux is only needed for live remote-drive — the
  instant nudge, `restart`, `compact`, the `/rename` keystroke, `inbox-watcher` — which skip
  gracefully without it. The one real reduction: an **idle** headless agent won't process a
  message until it's next prompted (nothing to wake it).
- **Work tracking.** Every substantive unit of work is one file under `docs/todos/<ID>.md`;
  `docs/TODO.md` is the **generated** index. Run substantive work through `/todo`.
- **Docs are load-bearing.** The `define-*` skills author the doc structure; `/todo` and
  `/base-pr` keep it in sync (including `docs/architecture.md`) before/at review.

## Skills

> **Authoring convention — keep `SKILL.md` lean.** A skill's `SKILL.md` is dumped into
> context in full on **every invocation**, so it holds only what the agent needs at
> **runtime**. Version history → a sibling `CHANGELOG.md` (not loaded); deep
> reference/internals → a linked `docs/*.md`; methodology shared across skills → one
> shared doc the skills point to (e.g. `AUDITING-SHARED.md`, `.claude/docs/fleet-base-workflow.md`).
> **Do not append changelog entries to `SKILL.md`** — record them in the skill's
> `CHANGELOG.md` (or rely on git log).

### Git workflow (local-first)
| Skill | What it does |
|---|---|
| `/base-push` | Land the current branch into **local** `<base>`, then publish to `origin`. The **only** skill that pushes `origin/<base>`. Defines the `merge_into_branch_local` helper. |
| `/base-merge` | Local-only sync of `<base>` ↔ the current branch (`down`/`up`); no network. |
| `/base-pr` | In-place PR-style review of what's new on local `<base>` (design / security / **doc-drift incl. architecture**); optionally apply fixes + promote locally. `--pr <n>` instead reviews a **GitHub PR** read-only and reports findings in the terminal (via `gh`, no posting). |
| `/base-test` | Merge local `<base>` into the current branch, run every project gate. Reports; no push. |
| `/open-pr` | Open a GitHub PR on a dedicated **frozen `pr/*` branch** rooted at the PR target (never the base!) — scoped from the TODO ledger's `commits:` or `--snapshot`. Create is user-gated; posts a **commit-manifest comment** (per-commit walkthrough + diff links, `--no-merges`); `--absorb` merges the merged PR back into the local base. Also **`--update <n>`** ("update pr 88") — revise an already-open PR **on its own head branch** (never rebuild locally + orphan it), merging the PR's base in before implementing (stacked-PR safe). |
| `/pr-comments` | Service a PR review round: full inventory, investigate-before-believing, clustered triage, internal-flow fixes + TODO linkage, peer package audit, **atomic user-gated posting**. |

### Inter-agent comms → [`docs/inter-agent-comms.md`](docs/inter-agent-comms.md)
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
| `/todo` | File-per-TODO lifecycle. Mints `AREA-<lane>NNN` IDs (`WORKFLOW_TODO_LANE`), regenerates `docs/TODO.md` via `scripts/gen-todos.mjs`. Complex plans pass a **plan-review gate** (reviewer-subagent `PLAN GREEN` → `plan_review:` frontmatter), then user sign-off on the gate's deltas, before implementation; the human is the terminal reviewer of every loop. |
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

### Plan
| Definition | What it does |
|---|---|
| [`planner` definition](agents/planner.md) | Authors a started TODO's plan doc (`/todo start`): investigates + collaborates with the human (agent panel) + writes `docs/todo_plans/<slug>.md`, returning an implementation handoff. Runs **in-cwd** (writes the real worktree — NOT isolation), plans-only (no source edits). Model: `WORKFLOW_PLAN_MODEL`, **default `fable`**. |

### Review + test
| Skill / definition | What it does |
|---|---|
| [`reviewer` definition](agents/reviewer.md) | THE review path: every session spawns it via the Agent tool — mode 1 (TODO-scoped plan/diff) or mode 2 (range/PR/bundle). Read-only, isolation-worktree, byte-exact `GREEN LIGHT`/`PLAN GREEN` verdicts. **Model-diverse**: rev-a `WORKFLOW_REVIEW_MODEL_A` (default `fable`), rev-b `WORKFLOW_REVIEW_MODEL_B` (default `sonnet`); a single reviewer runs `_B`; empty ⇒ inherit. |
| [`tester` definition](agents/tester.md) | THE test path: spawned **in place** on the worktree to run the project's quality-gate sweep (+ any E2E); zero git/source mutations. Model: `WORKFLOW_TEST_MODEL`, unset ⇒ inherit. |
| `/monocle-review` | The **human**-review gate — sends the diff to Monocle natively + attaches TODO/plan context, blocks on the verdict. |

> **Gate prompts use `AskUserQuestion`.** The workflow's choice gates present a **native
> multiple-choice** via the `AskUserQuestion` tool — not options printed as text with a typed
> reply. Both `/todo` review gates (plan **and** diff) ask **two independent questions in one
> call, never merged into a single choice**: **Q1 — Monocle _or not_** (the
> human-review engine) and **Q2 — Reviewers** (**Two reviewers / One reviewer / None** —
> spawns of the `reviewer` definition).
> The axes are orthogonal — choosing Monocle never skips agent review, and declining agent
> review never skips Monocle (canonical contract: `/monocle-review` → "Contract for the gates").
> If the user already specified a choice, skip that ask.

### Deep audit (language-agnostic) — escalated by `/base-pr` on high-risk diffs
`/feynman-auditor` · `/state-inconsistency-auditor` · `/nemesis-auditor`.

## Hooks (`hooks/`)
| Hook | Event | Role |
|---|---|---|
| `register-agent.sh` | SessionStart (+ self-heal) | Registers the agent, derives name + role, injects role context. Wired in **user-level** `~/.claude/settings.json` (SessionStart fires before project settings load). |
| `mark-busy.sh` | UserPromptSubmit + PreToolUse | Marks the agent busy so peers skip a redundant nudge mid-turn. |
| `drain-inbox.sh` (+ `.test.sh`) | Stop | Re-injects undelivered mailbox messages (at-least-once); GCs abandoned mail; clears the busy marker. |
| `unregister-agent.sh` | SessionEnd | Cleans up the registry entry + busy + error markers. |
| `mark-error.sh` | StopFailure | Marks the agent errored (`~/.claude/agent-error/<name>` = the failure category) and clears its busy marker so it can be nudged. The detection substrate the watcher reads. |
| `cc-watcher-keepalive.sh` | SessionStart + Stop | **Coordinator only.** Keeps exactly one `inbox-watcher` daemon alive machine-wide (idempotent `inbox-watcher.sh start` — launch on startup, self-heal on every Stop). One cc per machine → one watcher. |

## Scripts (`scripts/`)
`_config.sh` (config loader) · `_fleet.sh` (the canonical fleet predicates: liveness, busy, role, self, and `fleet_manifest_path` — the ONE resolver of the worktrees-manifest path) · `fleet-layout.sh` (layouts + `name-windows` + `boot` + `down`) · `workflow-local.sh` (the single writer of the gitignored `workflow.config.local`: `set` a machine-local knob, `seed` it into a new worktree) · `agent-send.sh` · `agent-broadcast.sh` · `agent-fanout.sh` ·
`agent-msg.sh` · `inbox-watcher.sh` (the coordinator-run re-nudge daemon: parked messages + retriable-errored agents; kept alive by `cc-watcher-keepalive.sh`) · `agent-rename.sh` ·
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
- [`docs/inter-agent-comms.md`](docs/inter-agent-comms.md) — full messaging + registration protocol.
- [`agent-roles/`](agent-roles/) — per-role startup instructions injected at SessionStart.
- Each skill's own `SKILL.md` under `skills/<name>/` — the authoritative, detailed spec.
