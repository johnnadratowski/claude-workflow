# Inter-Agent Communication

A lightweight mailbox + tmux-bridge that lets Claude Code sessions running in different tmux panes message each other. Useful when you're working in one worktree and want a peer agent in another worktree to take on a sub-task and report back.

## How it works

1. **Auto-registration.** `.claude/hooks/register-agent.sh` writes a file at `~/.claude/running-agents/<name>.<pid>` containing the session's `$TMUX_PANE`. The hook is configured in **user-level** `~/.claude/settings.json` for `SessionStart`, not project-local, because `SessionStart` fires before project settings are loaded — project-local SessionStart entries are silently rejected by Claude Code. The hook resolves the claude PID by parsing `session_id` from its stdin JSON and finding the `~/.claude/sessions/<pid>.json` whose contents match, then verifying the PID is alive and belongs to a `claude` process (session files accumulate across runs, so blind trust gives stale PIDs). Falls back to walking the process tree, then to `$PPID`. Agent name comes from the session file's `name` field (set by `/rename`; persists across resumes), then current git branch (sanitized: `/` → `-`), then cwd basename. The hook also sets the tmux pane title, renames the tmux window, and (on first startup) types `/rename <name>` so Claude's own session label, the tmux pane border (if `pane-border-status` is enabled), and the tmux tab all converge. Every invocation appends a line to `~/.claude/debug/register-agent.log` for troubleshooting.

2. **Base-branch tracking.** `~/.claude/agents/<name>` is a persistent file (one per agent) recording the git branch the agent considers its "home." First registration writes the current branch. On every subsequent registration, the hook compares stored vs. current; on mismatch it emits `hookSpecificOutput.additionalContext` so the model surfaces the warning to the human ("you're on branch X but agent N was registered with base branch Y — switch back?"). `/agent-rename <new>` renames the local git branch via `git branch -m`, updates this file, and renames everything else (registry, tmux, Claude session name) in lockstep.

3. **Sending.** `/agent-send <target> "<body>" [--reply]` first runs `register-agent.sh send-selfheal` as a prelude (idempotent — fast-path no-op when own entry is current) so a stale or missing own-entry is rebuilt before the send proceeds. Then writes the body to `~/.claude/agent-inbox/<uuid>.txt`, verifies the target's PID and tmux pane are still alive (pruning stale registry entries when not), and delivers `/agent-msg <self> <uuid>.txt [reply]` into the target's pane via `tmux send-keys`.

4. **Receiving.** The slash command `/agent-msg <sender> <filename> [reply]` lands in the recipient's prompt buffer. The `agent-msg` skill body instructs the recipient to read + delete the message file, print a visible banner so the human watching the terminal sees that input came from a peer agent, then either process the request (and reply via `agent-send --reply`) or just integrate the reply into the conversation.

5. **Cleanup.** `SessionEnd` removes the per-session registry file (`<name>.<pid>`) but leaves the persistent `~/.claude/agents/<name>` base-branch record. PID-not-alive checks at send time prune stragglers from unclean exits.

## Layout

| Path | Role |
|------|------|
| `.claude/hooks/register-agent.sh` | Idempotent registration script. Registered as `SessionStart` in **user-level** `~/.claude/settings.json`; also invoked as a self-heal prelude by `agent-send.sh` and `agent-rename.sh`. |
| `.claude/hooks/unregister-agent.sh` | `SessionEnd` hook in project-local settings — remove the per-session registry file. Send-time `kill -0` is the safety net for unclean exits. |
| `.claude/scripts/agent-send.sh` | Backing script for `/agent-send` |
| `.claude/scripts/agent-rename.sh` | Backing script for `/agent-rename` |
| `.claude/skills/agent-msg/SKILL.md` | Receiver-side handler (banner + request/reply branching) |
| `.claude/skills/agent-send/SKILL.md` | Sender-side dispatcher |
| `.claude/skills/agent-rename/SKILL.md` | Rename current agent (registry + tmux + claude session + git branch + base-branch file) |
| `~/.claude/running-agents/<name>.<pid>` | **Runtime, never tracked.** Per-session registry. Filename carries the claude PID; contents are the tmux pane id. Cleaned up on `SessionEnd`. |
| `~/.claude/agents/<name>` | **Persistent.** Agent's recorded base git branch. Written on first registration; consulted on every subsequent SessionStart to detect "you're on the wrong branch" drift. Updated by `/agent-rename`. |
| `~/.claude/agent-inbox/<uuid>.txt` | **Runtime, never tracked.** In-flight message bodies, deleted by the recipient after read. |
| `~/.claude/debug/register-agent.log` | Diagnostic log; one line per hook invocation with source, PID-discovery path, and outcome. |

## Slash commands

| Command | Use |
|---------|-----|
| `/agent-send <target> "<body>"` | Send a **request** to another agent. They are expected to reply via `agent-send --reply` once they have an answer. |
| `/agent-send <target> "<body>" --reply` | Send a **reply** to an agent who messaged you. Replies do not trigger auto-responses (breaks ping-pong loops). |
| `/agent-msg <sender> <filename> [reply]` | Receiver-side handler. Invoked automatically when another agent's `tmux send-keys` lands in your prompt buffer — you never type this yourself. |
| `/agent-rename <new-name>` | Rename this agent everywhere — registry, tmux pane title, tmux window, Claude session name. |

## Auto-discovery

A sending agent finds its own name by scanning `~/.claude/running-agents/` for the file whose **content** matches its own `$TMUX_PANE`. This works in any subprocess of Claude (the Bash tool, hooks, etc.) because `$TMUX_PANE` is inherited reliably; `$PPID` is not (intermediate shells in the Bash tool chain confuse it).

## Caveats

- **SessionStart hook lives at user-level, not project-local.** Claude Code loads project settings *after* the session starts, so a `SessionStart` entry in project `.claude/settings.json` is silently rejected. The wiring lives in `~/.claude/settings.json` and references `$CLAUDE_PROJECT_DIR/.claude/hooks/register-agent.sh` (via a git-toplevel walk — see `settings.json.example`) — when claude launches in a project that doesn't ship the script, the hook is a clean no-op. `SessionEnd` and `Stop` work fine in project-local settings (they fire after settings are loaded).
- **Single-line slash command on delivery.** `tmux send-keys` treats newlines as Enter, which would submit the prompt early. The body lives in a file, but the slash command itself is one line — no special characters to escape in the delivery format.
- **Mid-turn delivery queues.** If the recipient is mid-response when the message arrives, the slash command sits in their prompt buffer and fires at the start of the next turn. Acceptable for any non-real-time task.
- **Human typing collides.** If the human is keying into the target pane when `tmux send-keys` fires, bytes interleave. Property of `send-keys`; nothing this layer can fix.
- **No cross-machine.** Everything is local — registry, inbox, and tmux are all on the same host. Multi-machine fan-out would need a different transport.

## Adding a new agent message type

The current protocol is `request` and `reply`. To add a new type (say, `cancel` to abort a long-running task):

1. Extend `agent-send.sh` to accept the new flag and append the keyword after the filename when delivering.
2. Update `agent-msg/SKILL.md` so the recipient's branching logic recognizes the new type. Keep `request` and `reply` semantics intact.
3. If the new type changes the banner's visual style (different glyph, header text), update both the banner template and the description so the human can spot it at a glance.

The delivery format is intentionally positional and minimal — adding a fourth or fifth keyword is cheap; structural changes (e.g. moving to a JSON envelope) would require updating every caller.
