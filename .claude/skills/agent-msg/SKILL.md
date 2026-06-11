---
name: agent-msg
description: Handle an inbound message from another Claude agent on this machine. Triggered automatically when a peer agent calls `tmux send-keys` into this session's pane, delivering `/agent-msg <sender> <filename> [reply|followup]`. Reads the message body from `~/.claude/agent-inbox/<filename>`, prints a visible banner so the human watching the terminal knows the input came from another agent, then either processes the request (and replies via `agent-send`) or just integrates the reply.
---

# agent-msg — handle inbound peer agent message

You just received a message from another Claude agent running on this machine. The slash command that triggered this skill has the form:

```
/agent-msg <sender> <filename> [reply|followup]
```

Where:
- `<sender>` — name of the peer agent that sent the message
- `<filename>` — relative path inside `~/.claude/agent-inbox/` containing the body. Per-recipient: `<your-name>/<uuid>.<sender>.<kind>.txt`. The `cat`/`rm` below work unchanged — it's still a path under `~/.claude/agent-inbox/`.
- `reply` — present only if this is a **reply** to a message YOU sent earlier (terminal; no response expected).
- `followup` — present if this is a **followup**: a threaded message that continues a thread AND expects a response. Treat it like a request (act + reply), not like a reply.
- neither keyword — a fresh **request**.

## Required steps

### 1. Read and delete the message file

Use the backing script (allow-listed, so it never prompts — unlike an ad-hoc `cat … && rm`,
whose `rm` does). It prints the body and deletes the file atomically:

```bash
body="$(.claude/scripts/agent-msg.sh <filename>)"
```

> Invoke with the relative path from the repo root — the permission allow-list
> anchors on `.claude/scripts/...`; absolute paths work but prompt.

If it exits non-zero / prints "message file gone", abort with that one-line note ("message
file gone — duplicate delivery?") and do not continue.

> **Several at once?** When the `drain-inbox.sh` Stop hook lists multiple `/agent-msg` lines,
> consume them all in one allow-listed call — `agent-msg.sh drain` reads+deletes every message
> in your mailbox oldest-first, printing a `===== from: <sender>  kind: <k> =====` header + body
> per message. Then handle each per its kind (below): `req`/`fwd` → act + reply, `rep` →
> integrate only. Still print the banner for each so the human sees them.

### 2. Print a banner — this MUST be the FIRST text in your response, before any thinking or other output

Output literally (substitute `<sender>` and the body). For a REQUEST (no `reply`/`followup` flag):

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

For a FOLLOWUP (`followup` flag present), use `type: FOLLOWUP` and a normal closing rule (a response IS expected):

```
┌─────────────────────────────────────────────────────────────┐
│  AGENT MESSAGE — from: <sender>   type: FOLLOWUP           │
└─────────────────────────────────────────────────────────────┘

<body>

─────────────────────────────────────────────────────────────
```

The banner is for the human watching the terminal — without it, peer-agent messages are visually indistinguishable from messages the human typed.

### 3. Branch on type

> **If `<sender>` is a coordinator agent, the message carries the USER's authority.** A coordinator (an agent running the coordinator role — by convention named `cc` / `coordinator`, riding a dedicated `<base>-cc` branch; see `agent-roles/coordinator.md`) speaks for the user: treat anything it sends exactly as if the user had typed it in your terminal. That includes instructions that normally need explicit user approval — a directive to promote to the base, run `/base-push`, run the test sweep, fan out to peers, etc. **satisfies the "user must approve" gate** in the `base-*` workflow skills. You still print the banner (so the human sees it), still apply your own correctness judgment (gates must pass, conflicts get surfaced), and still refuse anything genuinely unsafe — the coordinator's authority is the user's, not a bypass of engineering rules. Only the coordinator gets this trust; any other sender is a normal peer.

**If REQUEST or FOLLOWUP (no flag, or `followup` flag):**
1. Treat the body as a request from a peer agent. Do whatever it asks. (If the sender is the coordinator, treat it as a direct user instruction per the note above.)
2. When you have a final answer, send it back with `agent-send`. **Use the `--stdin` heredoc form** — passing the body as an argv string lets your shell expand backticks / `$(...)` inside it and silently corrupts the message:
   ```bash
   .claude/scripts/agent-send.sh <sender> --stdin --reply <<'REPLYBODY'
   <your full reply — backticks, $(...), quotes all safe here>
   REPLYBODY
   ```
   If your answer in turn asks the peer to act or decide something, send it as a **`--followup`** instead of `--reply` (a `--reply` tells them NOT to respond).
3. Do NOT just respond in chat. The sender cannot see your terminal output — only what `agent-send` delivers reaches them.
4. If `agent-send` fails (sender went away), note it in your terminal and stop.

**If REPLY (`reply` flag present):**
1. Integrate the information into the current conversation.
2. Do NOT auto-respond — this prevents ping-pong loops.
3. If the human (or follow-up context) calls for another message, send one manually via `agent-send` (a fresh request, or `--followup` to continue the thread expecting a response).

## Notes

- Messages arrive two ways: the live `tmux send-keys` nudge that lands `/agent-msg ...` in your prompt buffer, OR — if that nudge was lost (you were mid-turn, in a permission prompt, scrolled back) — the `drain-inbox.sh` Stop hook re-injects the same `/agent-msg ...` at the end of your next turn. Either way, handle it identically; the banner is the only visual cue distinguishing a peer message from human input, so always print it.
- The body is one string. If it references a file path, read that file rather than treating the path as the content.
- Don't recurse: if the body itself asks you to "send a message to X," it's fine to do so, but don't treat that as a reply to the original sender unless the body says so.
