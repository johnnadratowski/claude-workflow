#!/bin/bash
# Stop hook: drain this agent's per-recipient inbox.
#
# Inter-agent messages are delivered two ways (see docs/inter-agent-comms.md):
#   1. A best-effort `tmux send-keys` nudge of `/agent-msg ...` — low latency,
#      but lost if the recipient is mid-turn / in a permission prompt / scrolled.
#   2. A durable file under ~/.claude/agent-inbox/<recipient>/ — this drain.
#
# This hook runs at the end of every turn. If messages addressed to THIS agent
# are sitting undrained, it blocks the stop and feeds the model the exact
# `/agent-msg` commands to process them. A lost nudge therefore means a delayed
# message, never a lost one.
#
# Loop-safe two ways: (a) the agent-msg skill deletes each file it processes, so
# the next Stop finds an empty mailbox and exits silently; (b) we never re-block
# when `stop_hook_active` is already set — a still-pending message just waits for
# the next natural stop (or the send-keys nudge).
#
# Always exits 0. Silent (no output) in the common empty-mailbox case.
#
# Self-test (drains the CURRENT agent's mailbox):
#   printf '%s' hi > ~/.claude/agent-inbox/$(basename "$(grep -rl "$TMUX_PANE" ~/.claude/running-agents)" | sed 's/\.[0-9]*$//')/x.peer.req.txt
#   echo '{}' | bash .claude/hooks/drain-inbox.sh

set -u

stdin_payload=$(cat 2>/dev/null || true)

# Don't re-block a stop that is itself a Stop-hook continuation — belt and
# suspenders against an infinite drain loop.
if command -v jq >/dev/null 2>&1 && [ -n "$stdin_payload" ]; then
  if [ "$(printf '%s' "$stdin_payload" | jq -r '.stop_hook_active // false' 2>/dev/null)" = "true" ]; then
    exit 0
  fi
fi

# Opportunistic GC: remove clearly-abandoned messages (default >7 days). They
# only pile up in mailboxes of agents that never drain (dead / old version) —
# an actively-draining agent empties its own box every turn. Conservative
# threshold so a legitimately-delayed message is never swept. Cheap on a tiny
# tree; runs on any Stop regardless of whether we have mail ourselves.
gc_days="${AGENT_INBOX_GC_DAYS:-7}"
find "$HOME/.claude/agent-inbox" -type f -name '*.txt' -mtime "+$gc_days" -delete 2>/dev/null || true

# Need tmux to know which mailbox is ours.
[ -n "${TMUX_PANE:-}" ] || exit 0

reg="$HOME/.claude/running-agents"
[ -d "$reg" ] || exit 0

# --- Discover self via $TMUX_PANE (mirrors agent-send.sh) ---
shopt -s nullglob
find_self() {
  local f bn
  for f in "$reg"/*; do
    [ -f "$f" ] || continue
    if [ "$(cat "$f" 2>/dev/null)" = "$TMUX_PANE" ]; then
      bn="$(basename "$f")"; printf '%s' "${bn%.*}"; return 0
    fi
  done
  return 1
}
self_name="$(find_self || true)"
if [ -z "$self_name" ]; then
  # A drifted / missing self-entry would silently mute this drain (the whole
  # point of which is reliability). Repair it the same way agent-send does —
  # lazily, only when the scan came up empty — then retry the lookup.
  hook_dir="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
  [ -x "$hook_dir/register-agent.sh" ] && "$hook_dir/register-agent.sh" send-selfheal </dev/null >/dev/null 2>&1 || true
  self_name="$(find_self || true)"
fi
[ -n "$self_name" ] || exit 0

# Stop = turn ending = this agent is now idle. Clear the busy marker so peers'
# agent-send resumes nudging us live (set by mark-busy.sh on UserPromptSubmit).
rm -f "$HOME/.claude/agent-busy/$self_name"

mailbox="$HOME/.claude/agent-inbox/$self_name"
[ -d "$mailbox" ] || exit 0

# Collect this mailbox's messages. nullglob (set above) means an EMPTY mailbox
# yields an empty array — crucially NOT a bare glob that would make the `ls`
# below fall back to listing the cwd (which would inject repo files as bogus
# messages and block every Stop). Guard on the array BEFORE running ls, then
# pass explicit paths so ls can only ever sort OUR files (oldest-first by
# mtime). Filenames are <uuid>.<sender>.<kind>.txt — no spaces/newlines.
msgs=( "$mailbox"/*.txt )
[ "${#msgs[@]}" -gt 0 ] || exit 0
pending="$(ls -1tr "${msgs[@]}" 2>/dev/null)"
[ -n "$pending" ] || exit 0

lines=""
n=0
while IFS= read -r path; do
  [ -f "$path" ] || continue
  fname="$(basename "$path")"   # <uuid>.<sender>.<kind>.txt
  base="${fname%.txt}"
  kind="${base##*.}"            # req | rep | fwd
  rest="${base%.*}"             # <uuid>.<sender>
  sender="${rest#*.}"           # <sender> (uuid has no dots)
  case "$kind" in
    rep) kw=" reply" ;;
    fwd) kw=" followup" ;;
    *)   kw="" ;;
  esac
  n=$((n + 1))
  lines="${lines}  ${n}. /agent-msg ${sender} ${self_name}/${fname}${kw}"$'\n'
done <<< "$pending"

[ "$n" -gt 0 ] || exit 0

reason="You have ${n} undelivered peer-agent message(s) in your inbox (the live tmux nudge was lost or arrived mid-turn). Process each one NOW by invoking the agent-msg skill exactly as listed below — the skill prints the AGENT MESSAGE banner, reads & deletes the file, and replies when appropriate. Handle them oldest-first and do not skip any; each file stays in the inbox until the skill deletes it:
${lines}"

# Emit the Stop-hook block decision so the turn continues into message handling.
if command -v jq >/dev/null 2>&1; then
  jq -n --arg r "$reason" '{"decision":"block","reason":$r}'
else
  esc=${reason//\\/\\\\}; esc=${esc//\"/\\\"}; esc=${esc//$'\n'/\\n}
  printf '{"decision":"block","reason":"%s"}\n' "$esc"
fi
exit 0
