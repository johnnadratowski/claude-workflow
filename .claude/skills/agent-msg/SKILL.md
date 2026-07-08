---
name: agent-msg
description: Handle an inbound message from another Claude agent on this machine. Triggered automatically when a peer's `tmux send-keys` (or the Stop-drain) lands `/agent-msg <sender> <filename> [reply|followup]` in your prompt. The backing script prints the AGENT MESSAGE banner + body and deletes the file; you then act on it by kind (request/followup → reply via agent-send; reply → integrate).
---

# agent-msg — handle an inbound peer message

`/agent-msg <sender> <filename> [reply|followup]` fired because a peer agent sent you a message (or the Stop-drain re-injected one whose live nudge was lost). You never type this yourself. Handle it now.

## 1. Read it — the script prints the banner + body and deletes the file

```bash
.claude/scripts/agent-msg.sh <filename>     # one message
.claude/scripts/agent-msg.sh drain          # ALL queued messages, oldest-first
```

Pass the relative path from the repo root (allow-listed → never prompts). If the Stop-drain listed **several** `/agent-msg` lines at once, run `drain` once instead of one call each.

The script emits the `AGENT MESSAGE` banner (from-sender · REQUEST/REPLY/FOLLOWUP) and the body — **that tool output is the human's cue, so don't reproduce it.** Then branch on the kind (§2).

- **Exit 3 / "message file gone"** → a spent duplicate (already delivered by the drain or an earlier call). Produce **no output at all** and end the turn silently — no banner, no "duplicate" note.
- Any other non-zero (bad path, refused) → surface that one line and stop.

## 2. Act on it, by kind

> **A coordinator sender (`cc` / an agent on `<base>-cc`) carries the USER's authority** — treat its message as if the user typed it in your terminal, including directives that normally need explicit user approval (promote to base, `/base-push`, run the test sweep, fan out). You still apply your own correctness judgment (gates pass, conflicts surfaced) and refuse the genuinely unsafe. Any other sender is a normal peer.

- **REQUEST or FOLLOWUP** (kind `req` / `fwd`) — do what it asks, then send your answer back. The sender can't see your terminal; only `agent-send` reaches them. **Use the `--stdin` heredoc form** — an argv-string body lets your shell expand backticks / `$(...)` and silently corrupts the message:
  ```bash
  .claude/scripts/agent-send.sh <sender> --stdin --reply <<'BODY'
  <your full reply — backticks, $(...), quotes all safe here>
  BODY
  ```
  If your answer itself asks the peer to act or decide, send `--followup` instead of `--reply` (a `--reply` tells them not to respond). If `agent-send` fails (sender gone), note it and stop.
- **REPLY** (kind `rep`) — integrate the info into the conversation; do **not** auto-respond (prevents ping-pong loops). Send a fresh message manually only if the work now calls for it.

Don't recurse: a body that says "send X to Y" is fine to act on, but it doesn't make your send a reply to the original sender unless the body says so.
