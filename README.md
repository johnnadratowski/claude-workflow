# claude-workflow

A drop-in `.claude/` for Claude Code projects that adds:

- **Inter-agent communication** — Claude sessions in different tmux panes can message each other (`/agent-send`, `/agent-msg`, `/agent-rename`).
- **Worktree-friendly base-branch workflow** — `/base-pull`, `/base-push`, `/base-merge`, `/base-pr`. The shared "trunk" branch is never checked out in any persistent worktree; promotions go through a short-lived transient worktree, with local and remote refs kept in lockstep.
- **Auto-registration hooks** — Claude sessions register themselves at startup with their git branch as the agent name (rename anytime with `/agent-rename`).

The base branch name is configurable per-project via `.claude/workflow.config`. Default is `main`.

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
chmod +x /path/to/your-project/.claude/hooks/*.sh /path/to/your-project/.claude/scripts/agent-*.sh
```

### 2. Create the per-project config

```bash
cp workflow.config.example /path/to/your-project/.claude/workflow.config
$EDITOR /path/to/your-project/.claude/workflow.config
```

Set `WORKFLOW_BASE_BRANCH` to whatever your trunk is called (`main`, `master`, `trunk`, `develop`, etc.). Optionally set `WORKFLOW_MAIN_PATH` if your main clone lives somewhere different from where you're running the skills.

### 3. Merge the project-level settings.json

The `SessionEnd` hook and the safety-rail deny rules go in your project's `.claude/settings.json`. See `.claude/settings.json.example` — copy the `hooks.SessionEnd` block and the `permissions.deny` list into your existing settings (if any), or use the example as a starting point.

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

## Troubleshooting

- **No log entries in `~/.claude/debug/register-agent.log`** — the SessionStart hook isn't firing. Check `/hooks` from inside a Claude session; if "SessionStart" shows no entries, the hook isn't loading. Verify (a) it's in **user-level** `~/.claude/settings.json`, not the project one; (b) the JSON parses (`jq . ~/.claude/settings.json`).
- **`agent-send` fails with "no agent named X"** — the target session isn't registered. Either the hook didn't fire for it, or it crashed without `SessionEnd` cleaning up. Have the target session run any `agent-*` command to force a self-heal, or restart the claude session.
- **`agent-send` fails with "agent X (pid N) is gone — pruned stale registry entry"** — the registry entry was stale. Self-heal-on-send pruned it. The target session probably has a new PID; have it run any `agent-*` command to re-register (or restart).
- **Hook fires but writes a wrong PID** — `register-agent.sh` walks the process tree to find the actual `claude` PID. If you see the wrong PID in the registry, your `claude` process command line doesn't start with `claude`; check `ps -p <pid> -o command=` and consider adjusting the regex in the script.

## What's in here

```
.claude/
├── hooks/
│   ├── register-agent.sh        Idempotent registration. Installed as
│   │                             SessionStart (user-level) + invoked as
│   │                             self-heal prelude by agent-send/rename.
│   └── unregister-agent.sh      SessionEnd hook (project-level).
├── scripts/
│   ├── _config.sh               Sourceable config loader.
│   ├── agent-send.sh            Backing script for /agent-send.
│   └── agent-rename.sh          Backing script for /agent-rename.
├── skills/
│   ├── agent-msg/               Inbound-message handler.
│   ├── agent-send/              Send to a peer agent.
│   ├── agent-rename/            Rename this agent everywhere.
│   ├── base-pull/               Merge origin/<base> INTO current branch.
│   ├── base-push/               Push current branch + advance LOCAL <base>
│   │                             + push to origin (defines the
│   │                             merge_into_branch_transient helper).
│   ├── base-merge/              Local-only sync of <base>.
│   ├── base-pr/                 Review pending state on <base>; promote.
│   └── base-test/               Merge local <base>, run all gates, report.
├── settings.json.example        Project-level settings (deny + SessionEnd).
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
    └── TODO.md                  Backlog with worked PROMPT and non-PROMPT examples.

docs/
└── inter-agent-comms.md         Protocol writeup for the comms layer.
```

## Skills reference

| Skill | What it does |
|---|---|
| **`/base-pull`** | Merge `origin/$WORKFLOW_BASE_BRANCH` into the current feature branch (without checking the base out anywhere). Pushes the feature first as a backup, then merges. Doesn't auto-push the merge — your call when to publish. |
| **`/base-push`** | Push the current feature branch to origin, then advance LOCAL `$WORKFLOW_BASE_BRANCH` to include those changes via a transient worktree, then push local to origin. Local and origin always end in lockstep. Defines `merge_into_branch_transient` (the helper the other base-* skills call). |
| **`/base-merge`** | Local-only sync (no fetch, no push). Two modes: `down` (merge locally-cached `origin/<base>` into current) and `up` (advance local `<base>` from current). Used when you want refs aligned without publishing. |
| **`/base-pr`** | Review what's pending on the base branch in a dedicated sandbox worktree. Runs project gates against the sandboxed state; optionally promotes to origin via the helper after gates pass. Reads `docs/best-practices.md` / `docs/architecture.md` / `docs/security.md` during review to flag rule violations. |
| **`/base-test`** | Merge LOCAL `$WORKFLOW_BASE_BRANCH` into the current branch, then run every project quality gate against the merged result. Operates in place — no sandbox, no commit, no push. Reports failures together (doesn't stop at the first). |
| **`/agent-send <target> "<body>" [--reply]`** | Send a message to another Claude session running in another tmux pane on this machine. Self-heals the registry before sending. Body is staged in `~/.claude/agent-inbox/`; delivery is a one-line slash command into the target's prompt. `--reply` distinguishes replies (don't auto-respond) from requests. |
| **`/agent-msg <sender> <filename> [reply]`** | Inbound-message handler. Invoked AUTOMATICALLY when a peer agent's `tmux send-keys` lands `/agent-msg ...` in your prompt buffer. Reads + deletes the message file, prints a visible banner, then either processes (request) or integrates (reply). You never type this yourself. |
| **`/agent-rename <new-name>`** | Rename this agent everywhere: registry file in `~/.claude/running-agents/`, persistent base-branch file in `~/.claude/agents/`, tmux pane title, tmux window name, Claude session label (via the built-in `/rename`), and the local git branch (`git branch -m`). |

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
After you /base-push from one worktree, every other live agent should
/base-pull to pick up the change. The two-line ritual:

You> /agent-send <peer-name> \
     "origin/<base> just advanced to <sha>. Please /base-pull."

   (peer agent runs /base-pull, replies with confirmation +
    any conflicts encountered)
```

Saves you switching panes to broadcast the news manually.

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
| `WORKFLOW_BASE_BRANCH` | `main` | The shared "trunk" branch other branches merge into and pull from. Used by `/base-pull`, `/base-push`, `/base-merge`, `/base-pr`. |
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
| `WORKFLOW_BASE_BRANCH` | `base-pull`, `base-push`, `base-merge`, `base-pr` |
| `WORKFLOW_MAIN_PATH` | `merge_into_branch_transient` helper inside `base-push` |
| `WORKFLOW_AGENT_*` | `register-agent.sh` only (via `_config.sh`) |

## Caveats

- **macOS / Linux only** — the scripts use `tmux`, `ps`, `jq`, `git`, and bash arrays. `jq` is a soft dependency for `register-agent.sh` (the session-id lookup degrades to process-tree walk without it).
- **tmux required** — the registry and message-delivery mechanism both rely on `tmux send-keys`. The hook silently no-ops when `$TMUX_PANE` is unset.
- **The base branch must not be checked out in any persistent worktree.** The transient-worktree helper checks it out as a branch (not detached), so a concurrent checkout elsewhere will make the helper fail. By design, the base branch only exists as a ref and only materializes briefly during a `/base-push` or `/base-pr` promotion.

## Adapting

- `base-pr` ships with a TODO marker for gates — fill in your project's lint/typecheck/test commands.
- The `permissions.allow` list in `settings.json.example` is empty by default. Add `Bash(git push origin <pattern>)` entries for the branch names your skills will push.
- If you want a different agent-name scheme (not the git branch), edit `register-agent.sh`'s "Determine agent name" section — the fallback chain is session-file `name` → git branch → cwd basename.
