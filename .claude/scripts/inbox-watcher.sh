#!/bin/bash
# Optional inbox watcher — re-nudges PARKED agents so messages don't wait on a
# human keystroke.
#
# The drain hook (.claude/hooks/drain-inbox.sh) already makes delivery lossless
# for any agent that takes another turn. This covers the one gap it cannot: a
# fully idle agent that has already Stopped and won't run its drain until
# something wakes it. Run this in its own tmux pane or as a background process;
# it is NOT auto-started (a long-running daemon doesn't belong in a hook).
#
# Usage: inbox-watcher.sh [interval_secs] [redeliver_after_secs]
#   defaults: interval=5, redeliver_after=30
#
# Each poll, for every staged message whose age >= redeliver_after that is still
# present, it reconstructs the original `/agent-msg <sender> <path> [reply|
# followup]` and send-keys it to the recipient's live pane (skipping panes in
# copy-mode). Nudging `touch`es the file, resetting its age — so a given message
# is re-nudged at most once per redeliver_after (portable throttle, no bash-4
# associative arrays). A processed message disappears (drain/skill deletes it),
# so the watcher naturally stops nudging it. Messages to a non-live recipient
# are left alone for the drain's time-based GC to collect.

set -u
interval="${1:-5}"
redeliver_after="${2:-30}"
inbox="$HOME/.claude/agent-inbox"
reg="$HOME/.claude/running-agents"

mtime_of() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }

# Live pane for an agent name, or empty if not live.
pane_for() {
  local target="$1" f bn pid pane
  shopt -s nullglob
  for f in "$reg/$target".*; do
    [ -f "$f" ] || continue
    bn="$(basename "$f")"; pid="${bn##*.}"; pane="$(cat "$f" 2>/dev/null)"
    kill -0 "$pid" 2>/dev/null || continue
    tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qx "$pane" || continue
    printf '%s' "$pane"; return 0
  done
  return 1
}

echo "inbox-watcher: interval=${interval}s redeliver_after=${redeliver_after}s inbox=$inbox" >&2
trap 'echo "inbox-watcher: stopping" >&2; exit 0' INT TERM

while :; do
  now=$(date +%s)
  shopt -s nullglob
  for path in "$inbox"/*/*.txt; do
    [ -f "$path" ] || continue
    mtime="$(mtime_of "$path")"; [ -n "$mtime" ] || mtime="$now"
    [ $(( now - mtime )) -ge "$redeliver_after" ] || continue

    recipient="$(basename "$(dirname "$path")")"
    fname="$(basename "$path")"
    base="${fname%.txt}"; kind="${base##*.}"; rest="${base%.*}"; sender="${rest#*.}"
    case "$kind" in rep) kw=" reply" ;; fwd) kw=" followup" ;; *) kw="" ;; esac

    pane="$(pane_for "$recipient" || true)"
    [ -n "$pane" ] || continue   # recipient not live — leave for GC
    [ "$(tmux display-message -p -t "$pane" '#{pane_in_mode}' 2>/dev/null || echo 0)" = "1" ] && continue
    # Skip busy recipients — their Stop-drain delivers at the end of the turn;
    # re-nudging a busy agent would just buffer and replay as a duplicate.
    bm="$HOME/.claude/agent-busy/$recipient"
    [ -f "$bm" ] && [ -n "$(find "$bm" -mmin -30 2>/dev/null)" ] && continue

    tmux send-keys -t "$pane" -l "/agent-msg $sender $recipient/$fname$kw"
    tmux send-keys -t "$pane" Enter
    touch "$path"   # reset age — throttles re-nudge to once per redeliver_after
    echo "re-nudged $recipient about $fname (sender=$sender kind=$kind)" >&2
  done
  sleep "$interval"
done
