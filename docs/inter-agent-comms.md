# Inter-Agent Communication

A lightweight mailbox + tmux-bridge that lets Claude Code sessions running in different tmux panes message each other. Useful when you're working in one worktree and want a peer agent in another worktree to take on a sub-task and report back.

## Branch coordination model (purely local)

The agent fleet coordinates on the **local** base branch (`$WORKFLOW_BASE_BRANCH`, default `main`), never `origin/<base>`. All worktrees on the machine share one `.git`, so `refs/heads/<base>` is a single shared ref every agent reads and advances — a peer's work is mergeable the moment it's *committed* (no push needed).

**`origin` is touched by exactly one skill: `/base-push`.** It publishes local `<base>` to `origin/<base>` (a one-way snapshot for backup / CI / other machines) when — and only when — a human runs it. There is **no pull skill**: origin is effectively write-only. If you ever need to ingest published remote state, that's a deliberate manual `git fetch` + merge.

| Skill | Touches `origin`? | Role |
|-------|-------------------|------|
| `/base-merge` | no | Local sync of `<base>` ↔ a feature branch (down/up). |
| `/base-pr` | no | Review + promote fixes into **local** `<base>` (or any `--base`). |
| `/base-test` | no | Merge **local** `<base>` in, run the gate sweep. |
| `/base-push` | **yes (publish only)** | Land a branch into local `<base>`, then `git push origin <base>`. |

All merges into `<base>` go through the canonical **local** transient-worktree helper `merge_into_branch_local` (defined in `base-push/SKILL.md`) — a throwaway worktree checked out on `<base>` so the merge never disturbs the caller's worktree, with no fetch and no push. Consequence: local `<base>` is normally *ahead* of `origin/<base>`; that's the expected steady state, not drift. Never check out the literal base branch in a worktree (it breaks `worktree add <base>` for everyone) — the coordinator agent rides a dedicated `<base>-cc` branch (or a detached `origin/<base>`) for a base-tracking worktree.

## How it works

1. **Auto-registration.** `.claude/hooks/register-agent.sh` writes a file at `~/.claude/running-agents/<name>.<pid>` containing the session's `$TMUX_PANE`. The hook is wired in **user-level** `~/.claude/settings.json` for `SessionStart`, not project-local, because `SessionStart` fires before project settings are loaded — project-local SessionStart entries are silently rejected by Claude Code. The hook resolves the claude PID by parsing `session_id` from its stdin JSON and finding the `~/.claude/sessions/<pid>.json` whose contents match, then verifying the PID is alive and belongs to a `claude` process (session files accumulate across runs, so blind trust gives stale PIDs). Falls back to walking the process tree, then to `$PPID`. Agent name comes from the session file's `name` field (set by `/rename`; persists across resumes), then `WORKFLOW_AGENT_DEFAULT_BRANCH` (if set in config), then current git branch (sanitized: `/` → `-`, optional `WORKFLOW_AGENT_NAME_TRANSFORM` + `WORKFLOW_AGENT_NAME_PREFIX` applied), then cwd basename. The hook also sets the tmux pane title, renames the tmux window, and (on first startup, unless `WORKFLOW_AGENT_SKIP_RENAME=1` or the session is already named correctly) types `/rename <name>` so Claude's own session label, the tmux pane border, and the tmux tab all converge. Every invocation appends a line to `~/.claude/debug/register-agent.log` for troubleshooting.
2. **Base-branch tracking.** `~/.claude/agents/<name>` is a persistent file (one per agent) recording the git branch the agent considers its "home." First registration writes the current branch (or the config-pinned `WORKFLOW_AGENT_DEFAULT_BRANCH`). On every subsequent registration, the hook compares stored vs. current; on mismatch it emits `hookSpecificOutput.additionalContext` so the model surfaces the warning to the human (suppress with `WORKFLOW_AGENT_SKIP_BRANCH_WARN=1`). `/agent-rename <new>` renames the local git branch via `git branch -m`, updates this file, and renames everything else (registry, tmux, Claude session name) in lockstep.
3. **Role context (per-type startup instructions).** On `SessionStart`, the hook derives the agent's **role** from its name — `*-test*`/`test-*` → `test`, `*-pr*`/`pr-*`/`*-review*` → `review`, `cc`/`*-cc`/`coordinator` → `coordinator`, else `feature` (override per-agent with a single word in `~/.claude/agents/<name>.role`) — reads `.claude/agent-roles/<role>.md` from the repo, and injects it via the same `additionalContext` payload as the base-branch warning. So a review agent boots already primed to review, a test agent to run the gate sweep, a feature agent to implement + doc-sync + hand off, etc. Edit the role files to change what each type is told; they ship with the repo, so changes propagate via merge-down and take effect on each agent's **next session start**.
4. **Sending.** `/agent-send <target> --stdin [--reply|--followup] <<'BODY'…BODY` (or the legacy `<target> "<body>"` form) first runs `register-agent.sh send-selfheal` as a prelude (idempotent — fast-path no-op when own entry is current) so a stale or missing own-entry is rebuilt before the send proceeds. Then writes the body to the recipient's **per-recipient mailbox** `~/.claude/agent-inbox/<target>/<uuid>.<self>.<kind>.txt` (kind = `req`|`rep`|`fwd`), verifies the target's PID and tmux pane are still alive (pruning stale registry entries when not), and delivers `/agent-msg <self> <target>/<uuid>.<self>.<kind>.txt [reply|followup]` into the target's pane via `tmux send-keys`. The file write is the durable delivery; the send-keys is only a latency optimization, and it is **skipped** in two cases — the drain delivers instead: (a) the target pane is in **copy-mode** (scrolled back), where the nudge would be swallowed; (b) the target is **busy mid-turn** (a fresh `~/.claude/agent-busy/<target>` marker — set by `mark-busy.sh` on the target's `UserPromptSubmit`, cleared by its drain on `Stop`). Skipping a busy target costs no latency — it can't act before its next `Stop` anyway, and the drain delivers there — and it eliminates the **duplicate** that a buffered nudge + drain would otherwise produce. **Prefer the `--stdin`/heredoc form for any non-trivial body:** passing the body as an argv string lets the *caller's* shell expand backticks / `$(...)` inside it before agent-send runs, which silently corrupts the message; a quoted heredoc is immune.
5. **Receiving.** The slash command `/agent-msg <sender> <filename> [reply|followup]` lands in the recipient's prompt buffer. The `agent-msg` skill body instructs the recipient to read + delete the message file, print a visible banner so the human watching the terminal sees that input came from a peer agent, then act on it: a **request** or **followup** is processed and answered (followup = a reply that *does* expect a response); a **reply** is just integrated (no response, breaking ping-pong loops).
6. **Reliable drain (no lost messages).** `tmux send-keys` is best-effort — if the recipient is mid-turn, sitting in a permission prompt, or scrolled back, the nudge can fail to register and the `/agent-msg` line never runs. So the body is staged in a **per-recipient** mailbox and `.claude/hooks/drain-inbox.sh` (wired as a project-local `Stop` hook) runs at the end of every turn: it discovers the agent's own name via `$TMUX_PANE` (self-healing a drifted/missing registration the same way `agent-send` does, lazily, if the scan comes up empty), scans `~/.claude/agent-inbox/<self>/` and, for any undrained message, blocks the stop and re-injects the exact `/agent-msg <sender> <path> [reply|followup]` (reconstructed from the filename — sender + kind are encoded in it, oldest-first by mtime). A lost nudge is therefore a *delayed* message, never a lost one. Loop-safe: the `agent-msg` skill deletes each file it processes (next Stop finds an empty mailbox), and the drain never re-blocks when `stop_hook_active` is already set. The drain also **GCs abandoned messages** (default >7 days, `AGENT_INBOX_GC_DAYS`) that pile up in mailboxes of agents that never drain.
7. **Cleanup.** `SessionEnd` removes the per-session registry file (`<name>.<pid>`) and clears the busy marker, but leaves the persistent `~/.claude/agents/<name>` base-branch record. PID-not-alive checks at send time prune stragglers from unclean exits. Message files are removed by the recipient when processed; the per-recipient mailbox dir is created lazily on first send. A mailbox is **not** deleted on `SessionEnd` (the agent may resume and still need its messages) — truly-abandoned files are reaped by the drain's time-based GC instead.
8. **Waking parked agents (optional).** The drain covers any agent that takes another turn, but a fully idle agent has already Stopped and won't run its drain until woken. `.claude/scripts/inbox-watcher.sh` is an **opt-in** poller (run it in its own pane) that re-nudges live recipients with the reconstructed `/agent-msg` for any message left sitting past a timeout — closing that last gap without a daemon in the hook path.

## Layout

| Path | Role |
|------|------|
| `.claude/hooks/register-agent.sh` | Idempotent registration script. Wired as `SessionStart` in user-level `~/.claude/settings.json`; also invoked as a self-heal prelude by `agent-send.sh` and `agent-rename.sh`. On `SessionStart` it also injects role context (below) via `additionalContext`. |
| `.claude/agent-roles/<role>.md` | Per-role startup instructions (`feature`/`review`/`test`/`coordinator`) injected at `SessionStart` based on the agent's name. Edit to change what each agent type is told. |
| `~/.claude/agents/<name>.role` | **Optional, per-machine.** One word; overrides the name-derived role for that agent. |
| `.claude/hooks/mark-busy.sh` | `UserPromptSubmit` hook (project-local settings) — touches `~/.claude/agent-busy/<name>` so peers' `agent-send` skips the redundant nudge while this agent is mid-turn. Cleared by `drain-inbox.sh` (Stop) and `unregister-agent.sh` (SessionEnd). |
| `.claude/hooks/unregister-agent.sh` | `SessionEnd` hook in project-local settings — remove the per-session registry file + busy marker. Send-time `kill -0` is the safety net for unclean exits. |
| `.claude/hooks/drain-inbox.sh` | `Stop` hook in project-local settings — drains this agent's per-recipient mailbox, re-injecting any `/agent-msg` the live nudge dropped. Makes delivery at-least-once. Also GCs abandoned messages and lazily self-heals a drifted registration. |
| `.claude/hooks/drain-inbox.test.sh` | Hermetic test suite for the drain (run: `bash .claude/hooks/drain-inbox.test.sh`). Locks in the empty-mailbox, dot-delimiter, GC, kind-parse, and self-heal invariants. |
| `.claude/scripts/agent-send.sh` | Backing script for `/agent-send` (supports `--stdin` heredoc bodies, `--reply`, `--followup`) |
| `.claude/scripts/agent-broadcast.sh` | Backing script for `/agent-broadcast` — fan-out to all live peers |
| `.claude/scripts/agent-fanout.sh` | Backing script for `/agent-fanout` — `status` / `merge-down` / `send` / `restart` (allow-listed; `restart` needs `--yes`) |
| `.claude/scripts/agent-msg.sh` | Backing script for `/agent-msg` — read+delete one message, or `drain` the whole mailbox (allow-listed, so no ad-hoc `cat`+`rm`) |
| `.claude/scripts/inbox-watcher.sh` | Opt-in poller that re-nudges parked (already-Stopped) agents. Not auto-started. |
| `.claude/scripts/agent-rename.sh` | Backing script for `/agent-rename` |
| `.claude/skills/agent-msg/SKILL.md` | Receiver-side handler (banner + request/reply/followup branching) |
| `.claude/skills/agent-send/SKILL.md` | Sender-side dispatcher |
| `.claude/skills/agent-broadcast/SKILL.md` | Fan-out dispatcher (carries an explicit user-authorization gate) |
| `.claude/skills/agent-fanout/SKILL.md` | Fleet orchestration — status / role-targeted fan-out / merge-down / idle-gated restart |
| `.claude/skills/agent-rename/SKILL.md` | Rename current agent (registry + tmux + claude session + git branch + base-branch file) |
| `~/.claude/running-agents/<name>.<pid>` | **Runtime, never tracked.** Per-session registry. Filename carries the claude PID; contents are the tmux pane id. Cleaned up on `SessionEnd`. |
| `~/.claude/agents/<name>` | **Persistent.** Agent's recorded base git branch. Written on first registration; consulted on every subsequent SessionStart to detect "you're on the wrong branch" drift. Updated by `/agent-rename`. |
| `~/.claude/agent-inbox/<recipient>/<uuid>.<sender>.<kind>.txt` | **Runtime, never tracked.** Per-recipient mailbox; `<kind>` is `req`\|`rep`\|`fwd`. In-flight message bodies, deleted by the recipient after read; undrained ones are re-injected by `drain-inbox.sh`, and abandoned ones (>7d) are GC'd by it. |
| `~/.claude/agent-busy/<name>` | **Runtime, never tracked.** Present (and fresh, <30 min) while the agent is mid-turn. Lets a sender skip the redundant live nudge for a busy target. Set on `UserPromptSubmit`, cleared on `Stop`/`SessionEnd`. |
| `~/.claude/debug/register-agent.log` | Diagnostic log; one line per hook invocation with source, PID-discovery path, and outcome. |

## Slash commands

| Command | Use |
|---------|-----|
| `/agent-send <target> --stdin <<'BODY'…BODY` | Send a **request** (heredoc body, expansion-safe — preferred). The peer acts and replies. |
| `/agent-send <target> "<body>"` | Same, inline body. Fine for short, metachar-free one-liners only. |
| `/agent-send <target> … --reply` | Send a **reply** (terminal; no response expected — breaks ping-pong loops). |
| `/agent-send <target> … --followup` | Send a **followup**: a threaded message that **does** expect a response. Use instead of `--reply` when your reply asks the peer to act. |
| `/agent-broadcast --stdin <<'BODY'…BODY` | Fan out one message to **all live peers** (`--exclude a,b`, `--followup`, `--dry-run`). High blast-radius — needs explicit user authorization. |
| `/agent-fanout status` / `… msg --role <r>` / `… merge-down` / `… restart` | Fleet orchestration: read-only fleet snapshot, role-targeted message fan-out, canned post-push sync, and idle-gated force-restart (`claude --continue`, always confirmed). High blast-radius — see the skill. |
| `/agent-msg <sender> <filename> [reply\|followup]` | Receiver-side handler. Invoked automatically when another agent's `tmux send-keys` (or the drain) lands in your prompt buffer — you never type this yourself. |
| `/agent-rename <new-name>` | Rename this agent everywhere — registry, tmux pane title, tmux window, Claude session name. |

## Auto-discovery

A sending agent finds its own name by scanning `~/.claude/running-agents/` for the file whose **content** matches its own `$TMUX_PANE`. This works in any subprocess of Claude (the Bash tool, hooks, etc.) because `$TMUX_PANE` is inherited reliably; `$PPID` is not (intermediate shells in the Bash tool chain confuse it).

## Caveats

- **SessionStart hook lives at user-level, not project-local.** Claude Code loads project settings *after* the session starts, so a `SessionStart` entry in `.claude/settings.json` is silently rejected. The wiring lives in `~/.claude/settings.json` and walks up to the git toplevel to find `$repo/.claude/hooks/register-agent.sh` — when claude launches in another project, the path resolves to a script that doesn't exist and the hook is a clean no-op. `SessionEnd`, `Stop`, and `UserPromptSubmit` work fine in project-local settings (they fire after settings are loaded).
- **Single-line slash command on delivery.** `tmux send-keys` treats newlines as Enter, which would submit the prompt early. The body lives in a file, but the slash command itself is one line — no special characters to escape in the wire format.
- **Body corruption via argv expansion — use `--stdin`.** When a *sending* agent builds the `agent-send` call with the body inside double quotes, the sender's own shell expands backticks and `$(...)` in the body *before* `agent-send` runs, silently corrupting the message. Always prefer `agent-send <target> --stdin <<'BODY' … BODY` (quoted heredoc) for anything that might contain shell metacharacters. The inline `"<body>"` form is for short, metachar-free one-liners only.
- **Mid-turn delivery queues, then drains.** If the recipient is mid-response when the nudge arrives, the slash command sits in their prompt buffer and fires at the start of the next turn. If the nudge fails entirely, `drain-inbox.sh` re-injects it from the durable mailbox at the next `Stop`. Either way the message lands; only latency varies.
- **Human typing collides.** If the human is keying into the target pane when `tmux send-keys` fires, bytes interleave and the nudge may be garbled. Property of `send-keys`; nothing this layer can fix — but the drain still delivers the message from the mailbox regardless, so a garbled nudge is not a lost message.
- **No cross-machine.** Everything is local — registry, inbox, and tmux are all on the same host. Multi-machine fan-out would need a different transport.

## Adding a new agent message type

The current protocol is `request` (`req`), `reply` (`rep`), and `followup` (`fwd`). To add another (say, `cancel` to abort a long-running task):

1. Extend `agent-send.sh` to accept the new flag, encode the new `<kind>` token in the staged filename (`<uuid>.<self>.<kind>.txt`), and append the keyword after the path when delivering. Keeping the kind in the filename is what lets `drain-inbox.sh` reconstruct the right `/agent-msg` for a dropped nudge.
2. Update `agent-msg/SKILL.md` so the recipient's branching logic recognizes the new type, and teach **both** `drain-inbox.sh` and `inbox-watcher.sh` to map the new `<kind>` token to its delivery keyword. Add a case to `drain-inbox.test.sh`. Keep `req`/`rep`/`fwd` semantics intact.
3. If the new type changes the banner's visual style (different glyph, header text), update both the banner template and the description so the human can spot it at a glance.

The wire format is intentionally positional and minimal — adding a fourth or fifth keyword is cheap; structural changes (e.g. moving to a JSON envelope) would require updating every caller.
