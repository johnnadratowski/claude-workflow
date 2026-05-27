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
│   ├── register-agent.sh        Idempotent registration script. Installed as
│   │                             SessionStart (user-level) + invoked as
│   │                             self-heal prelude by agent-send/rename.
│   └── unregister-agent.sh      SessionEnd hook (project-level).
├── scripts/
│   ├── _config.sh               Sourceable config loader. Reads
│   │                             .claude/workflow.config; exports
│   │                             $WORKFLOW_BASE_BRANCH + $WORKFLOW_MAIN_PATH.
│   ├── agent-send.sh            Backing script for /agent-send.
│   └── agent-rename.sh          Backing script for /agent-rename.
├── skills/
│   ├── agent-msg/               Inbound-message handler.
│   ├── agent-send/              Send to a peer agent.
│   ├── agent-rename/            Rename this agent (registry + tmux + claude session + git branch).
│   ├── base-pull/               Merge origin/<base> INTO current branch.
│   ├── base-push/               Push current branch + advance LOCAL <base> + push to origin.
│   │                             Defines merge_into_branch_transient helper.
│   ├── base-merge/              Local-only sync of <base> (no fetch, no push).
│   └── base-pr/                 Review pending state on <base> in a sandbox;
│                                 optionally promote via the helper.
├── settings.json.example        Project-level settings (deny rules + SessionEnd hook).
└── settings-user-level.json.example   The SessionStart hook for ~/.claude/settings.json.

workflow.config.example          Sample config file with $WORKFLOW_BASE_BRANCH etc.

docs/
└── inter-agent-comms.md         Protocol writeup for /agent-msg / /agent-send.
```

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
