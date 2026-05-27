---
name: agent-msg
description: Handle an inbound message from another Claude agent on this machine. Triggered automatically when a peer agent calls `tmux send-keys` into this session's pane, delivering `/agent-msg <sender> <filename> [reply]`. Reads the message body from `~/.claude/agent-inbox/<filename>`, prints a visible banner so the human watching the terminal knows the input came from another agent, then either processes the request (and replies via `agent-send`) or just integrates the reply.
---

# agent-msg — handle inbound peer agent message

You just received a message from another Claude agent running on this machine. The slash command that triggered this skill has the form:

```
/agent-msg <sender> <filename> [reply]
```

Where:
- `<sender>` — name of the peer agent that sent the message
- `<filename>` — relative path inside `~/.claude/agent-inbox/` containing the body
- `reply` — present only if this is a reply to a message YOU sent earlier

## Required steps

### 1. Read and delete the message file

```bash
body=$(cat ~/.claude/agent-inbox/<filename>) && rm ~/.claude/agent-inbox/<filename>
```

If the file doesn't exist, abort with a one-line note ("message file gone — duplicate delivery?") and do not continue.

### 2. Print a banner — this MUST be the FIRST text in your response, before any thinking or other output

Output literally (substitute `<sender>` and the body). For a REQUEST (no `reply` flag):

```
┌─────────────────────────────────────────────────────────────┐
│  AGENT MESSAGE — from: <sender>   type: REQUEST             │
└─────────────────────────────────────────────────────────────┘

<body>

─────────────────────────────────────────────────────────────
```

For a REPLY (`reply` flag present), change the type line to `type: REPLY` and add `(no auto-response)` on the closing rule:

```
┌─────────────────────────────────────────────────────────────┐
│  AGENT MESSAGE — from: <sender>   type: REPLY               │
└─────────────────────────────────────────────────────────────┘

<body>

───────────────────────────────────────── (no auto-response) ─
```

The banner is for the human watching the terminal — without it, peer-agent messages are visually indistinguishable from messages the human typed.

### 3. Branch on type

**If REQUEST (no `reply` flag):**
1. Treat the body as a request from a peer agent. Do whatever it asks.
2. When you have a final answer, send it back using the `agent-send` skill with the `--reply` flag:
   ```bash
   "$(git rev-parse --show-toplevel)/.claude/scripts/agent-send.sh" <sender> "<your full reply>" --reply
   ```
3. Do NOT just respond in chat. The sender cannot see your terminal output — only what `agent-send` delivers reaches them.
4. If `agent-send` fails (sender went away), note it in your terminal and stop.

**If REPLY (`reply` flag present):**
1. Integrate the information into the current conversation.
2. Do NOT auto-respond — this prevents ping-pong loops.
3. If the human (or follow-up context) calls for another message, send one manually via `agent-send` without `--reply` to start a new request thread.

## Notes

- Messages arrive in your prompt buffer as if the human typed them — the banner is the only visual cue distinguishing them. Always print it.
- The body is one string. If it references a file path, read that file rather than treating the path as the content.
- Don't recurse: if the body itself asks you to "send a message to X," it's fine to do so, but don't treat that as a reply to the original sender unless the body says so.
