#!/bin/bash
# UserPromptSubmit + PreToolUse hook: mark this agent BUSY.
#
# UserPromptSubmit marks the turn START; PreToolUse re-touches the marker on
# every tool call so it stays FRESH through turns that never had a prompt
# submit at all — background-task notifications and Stop-hook continuations
# start turns without UserPromptSubmit, and were invisible to the idle-guard
# (senders nudged a working agent; the buffered nudge always loses to the
# Stop-drain and replays as a duplicate).
#
# A peer's agent-send reads this marker and SKIPS the live tmux nudge when the
# target is busy — the target's Stop-drain (drain-inbox.sh) will deliver the
# staged message at the end of its current turn anyway, so the nudge would only
# buffer and replay as a duplicate. Marker is cleared on Stop (drain-inbox.sh)
# and SessionEnd (unregister-agent.sh).
#
# Keyed by agent name (mirrors the registry). Shared ~/.claude so peers can read
# it. Silent, always exits 0. A missing marker just means "treat as idle" — a
# safe degradation (worst case: a duplicate nudge, which the agent-msg file-gone
# guard absorbs).

set -u
cat >/dev/null 2>&1 || true   # drain hook stdin

[ -n "${TMUX_PANE:-}" ] || exit 0
reg="$HOME/.claude/running-agents"
[ -d "$reg" ] || exit 0

shopt -s nullglob
for f in "$reg"/*; do
  [ -f "$f" ] || continue
  if [ "$(cat "$f" 2>/dev/null)" = "$TMUX_PANE" ]; then
    bn="$(basename "$f")"
    mkdir -p "$HOME/.claude/agent-busy"
    : > "$HOME/.claude/agent-busy/${bn%.*}"
    break
  fi
done
exit 0
