#!/bin/bash
# Fleet watcher — the SINGLE engine that re-nudges (1) PARKED agents so messages don't
# wait on a human keystroke, and (2) ERRORED agents (retriable StopFailure) to continue.
# Both nudges are pure tmux send-keys — NO model/agent calls.
#
# Lifecycle: the COORDINATOR (cc) owns it. cc-watcher-keepalive.sh starts it on the
# coordinator's SessionStart and re-starts it (idempotent `start`) on every cc Stop, so
# a single instance runs machine-wide for as long as a cc is alive (one cc per machine →
# one watcher). The errored-agent SWEEP lives HERE, not in the hook — the hook only keeps
# this daemon up, so the nudge logic isn't duplicated across the two.
#
# The drain hook (.claude/hooks/drain-inbox.sh) still makes message delivery lossless for
# any agent that takes another turn; this daemon covers the idle-fleet gap it can't: a
# parked agent that won't run its drain, or an errored agent sitting idle.
#
# Usage:
#   inbox-watcher.sh [interval_secs] [redeliver_after_secs]   # run the poll loop (foreground)
#   inbox-watcher.sh start [interval] [redeliver]             # spawn ONE detached daemon (single-instance)
#   inbox-watcher.sh stop                                     # kill the daemon
#   inbox-watcher.sh status                                   # running? (pid)
#   defaults: interval=5, redeliver_after=30
# The start/stop/status control mode (single-instance via a pidfile) is what the
# coordinator's cc-watcher-keepalive.sh hook uses to keep exactly one instance alive.
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

# --- daemon control (single-instance via pidfile) ---------------------------
# `start` spawns ONE detached copy running the poll loop and records its pid;
# a second `start` while one is live is a no-op. `stop`/`status` don't need tmux.
PIDFILE="$HOME/.claude/inbox-watcher.pid"
_running_pid() { local p; [ -f "$PIDFILE" ] && p="$(cat "$PIDFILE" 2>/dev/null)" && [ -n "$p" ] && kill -0 "$p" 2>/dev/null && printf '%s' "$p"; }
case "${1:-}" in
  start)
    shift
    p="$(_running_pid || true)"; [ -n "$p" ] && { echo "inbox-watcher: already running (pid $p)"; exit 0; }
    mkdir -p "$(dirname "$PIDFILE")"
    nohup "$0" "$@" >/dev/null 2>&1 &            # re-exec self in loop mode, detached
    echo $! > "$PIDFILE"
    echo "inbox-watcher: started (pid $(cat "$PIDFILE"))"; exit 0 ;;
  stop)
    p="$(_running_pid || true)"; if [ -n "$p" ]; then kill "$p" 2>/dev/null; echo "inbox-watcher: stopped (pid $p)"; else echo "inbox-watcher: not running"; fi
    rm -f "$PIDFILE"; exit 0 ;;
  status)
    p="$(_running_pid || true)"; [ -n "$p" ] && echo "inbox-watcher: running (pid $p)" || echo "inbox-watcher: not running"; exit 0 ;;
esac

# This watcher's entire job is to re-NUDGE parked agents via tmux send-keys, so it
# is a tmux-only convenience (DX-jn-8-019). Without tmux there's nothing it can do —
# the durable mailbox + Stop-drain still deliver at each agent's next turn.
if [ -z "${TMUX_PANE:-}" ] && ! command -v tmux >/dev/null 2>&1; then
  echo "inbox-watcher: tmux unavailable — nothing to nudge (messages still drain at each agent's next turn); exiting." >&2
  exit 0
fi
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
    [ -f "$bm" ] && [ -n "$(find "$bm" -mmin -5 2>/dev/null)" ] && continue

    # Claim delivery FIRST (same as agent-send): the target's Stop-drain skips this fresh-claimed
    # file so it won't ALSO inject it → no "file gone" duplicate. Claim before the send-keys to
    # close the drain-in-the-gap window. Cleared on delivery.
    mkdir -p "$HOME/.claude/agent-nudge-claim" 2>/dev/null || true
    : > "$HOME/.claude/agent-nudge-claim/$fname" 2>/dev/null || true
    tmux send-keys -t "$pane" -l "/agent-msg $sender $recipient/$fname$kw"
    tmux send-keys -t "$pane" Enter
    touch "$path"   # reset age — throttles re-nudge to once per redeliver_after
    echo "re-nudged $recipient about $fname (sender=$sender kind=$kind)" >&2
  done

  # (2) Nudge ERRORED agents (retriable StopFailure) to continue. This is the SOLE
  # errored-agent sweep — the cc keep-alive hook no longer duplicates it. Throttled via
  # ~/.claude/agent-nudged/<name> so a given agent is nudged at most once per window.
  throttle_min="${WORKFLOW_RESUME_THROTTLE_MIN:-2}"
  nudged_dir="$HOME/.claude/agent-nudged"; mkdir -p "$nudged_dir"
  for ef in "$HOME/.claude/agent-error"/*; do
    [ -f "$ef" ] || continue
    name="$(basename "$ef")"
    # Only nudge RETRIABLE error categories (the marker's content, written by mark-error.sh).
    # "Continue" can't fix auth/billing/invalid_request — nudging those would just retry a
    # doomed error every throttle window. Those (and unparsed "error") are left for the user.
    case "$(head -1 "$ef" 2>/dev/null)" in rate_limit|overloaded|server_error) ;; *) continue ;; esac
    pane="$(pane_for "$name" || true)"; [ -n "$pane" ] || continue   # not live → skip
    [ "$(tmux display-message -p -t "$pane" '#{pane_in_mode}' 2>/dev/null || echo 0)" = "1" ] && continue
    tf="$nudged_dir/$name"
    [ -f "$tf" ] && [ -n "$(find "$tf" -mmin "-$throttle_min" 2>/dev/null)" ] && continue
    tmux send-keys -t "$pane" -l "Continue — the API rate limit should have cleared. Resume where you left off."
    tmux send-keys -t "$pane" Enter
    : > "$tf"
    echo "nudged errored agent $name to continue (pane $pane)" >&2
  done

  sleep "$interval"
done
