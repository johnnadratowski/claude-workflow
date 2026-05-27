---
name: agent-send
description: Send a message to another Claude agent running on this machine. Use to dispatch a task to a peer agent or to reply to one. Args are `<target> "<body>" [--reply]`. The peer receives the message in its prompt as `/agent-msg <you> <filename> [reply]`, which loads the `agent-msg` skill on their end.
---

# agent-send — send a message to a peer agent

Send a message to another Claude agent. The body is written to `~/.claude/agent-inbox/<uuid>.txt` and the target's tmux pane receives `/agent-msg <you> <uuid>.txt [reply]` in its prompt.

## Usage

```bash
"$(git rev-parse --show-toplevel)/.claude/scripts/agent-send.sh" <target> "<body>" [--reply]
```

- `<target>` — name of the destination agent. List active agents with:
  ```bash
  ls ~/.claude/running-agents/ | sed 's/\.[0-9]*$//' | sort -u
  ```
- `<body>` — message content as a single shell-quoted string. Can be any length; written to a file, not the prompt. Multi-line content is fine inside the quotes.
- `--reply` — pass this flag if and only if you're replying to a message you just received via `agent-msg`. Replies don't trigger auto-responses on the receiving end (prevents ping-pong loops).

## What happens

1. Self-discovery: script finds your own agent name from `~/.claude/running-agents/` (matching by `$TMUX_PANE`).
2. Target lookup: finds `~/.claude/running-agents/<target>.<pid>`.
3. Liveness check: verifies the target's claude PID is alive AND its tmux pane still exists. Stale entries are pruned automatically.
4. Stages the body file in `~/.claude/agent-inbox/`.
5. Delivers `/agent-msg <you> <uuid>.txt [reply]` to the target's pane via `tmux send-keys`.

## Failure modes

The script exits non-zero and prints to stderr if:
- This agent isn't registered (the SessionStart hook didn't run, or `$TMUX_PANE` isn't set)
- The target agent name has no entry in the registry
- The target's claude PID is dead (stale entry pruned)
- The target's tmux pane is gone (stale entry pruned)

Caveats:
- If the target is mid-turn when the message arrives, it queues in the prompt buffer and is processed at the start of its next turn.
- If the human is actively typing into the target's terminal, your message will interleave with their keystrokes. There's no fix at this layer — just an inherent property of tmux send-keys.
