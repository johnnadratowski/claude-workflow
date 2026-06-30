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

reg="$HOME/.claude/running-agents"
[ -d "$reg" ] || exit 0

# Self-id via the identity token (pane in tmux, else cwd-based) — works headless (DX-jn-8-019).
hook_dir="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
# shellcheck disable=SC1090
[ -r "$hook_dir/../scripts/_fleet.sh" ] && . "$hook_dir/../scripts/_fleet.sh"
self_name="$(fleet_find_self "$reg" 2>/dev/null || true)"
if [ -n "$self_name" ]; then
  mkdir -p "$HOME/.claude/agent-busy"
  : > "$HOME/.claude/agent-busy/$self_name"
  rm -f "$HOME/.claude/agent-error/$self_name"   # activity = recovered from any prior StopFailure
fi
exit 0
