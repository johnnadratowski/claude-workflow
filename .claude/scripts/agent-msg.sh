#!/bin/bash
# Backing script for the /agent-msg receiver skill: atomically read + delete a peer
# message from THIS agent's inbox, so the skill never needs ad-hoc `cat … && rm`
# (the `rm` prompts; `cat` alone doesn't delete). Only ever touches files under
# ~/.claude/agent-inbox/.
#
#   agent-msg.sh <relpath>   Print the body of ~/.claude/agent-inbox/<relpath>, then delete it.
#                            (Single-message form the skill uses per /agent-msg invocation —
#                             the sender + kind come from the slash-command args.)
#   agent-msg.sh drain       Read+delete EVERY message in THIS agent's mailbox, oldest-first,
#                            printing a "===== from: <sender>  kind: <k> =====" header + body
#                            per message. Handy when the Stop-drain lists several at once.

set -u
inbox="$HOME/.claude/agent-inbox"
claims="$HOME/.claude/agent-nudge-claim"   # delivery-claim markers (see agent-send.sh / drain-inbox.sh)

case "${1:-}" in
  drain)
    reg="$HOME/.claude/running-agents"; self=""
    shopt -s nullglob
    for f in "$reg"/*; do
      [ -f "$f" ] && [ "$(cat "$f" 2>/dev/null)" = "${TMUX_PANE:-}" ] && { self="$(basename "$f" | sed 's/\.[0-9]*$//')"; break; }
    done
    [ -n "$self" ] || { echo "not registered (can't find own mailbox)"; exit 1; }
    mb="$inbox/$self"; [ -d "$mb" ] || { echo "(empty mailbox)"; exit 0; }
    msgs=( "$mb"/*.txt ); [ "${#msgs[@]}" -gt 0 ] || { echo "(empty mailbox)"; exit 0; }
    while IFS= read -r p; do
      [ -f "$p" ] || continue
      fn="$(basename "$p")"; base="${fn%.txt}"; kind="${base##*.}"; rest="${base%.*}"; sender="${rest#*.}"
      echo "===== from: $sender  kind: $kind ====="
      cat "$p"; printf '\n'
      rm -f "$p"; rm -f "$claims/$fn"   # delivered → release the delivery-claim
    done < <(ls -1tr "${msgs[@]}")
    ;;
  ""|-h|--help)
    echo "usage: agent-msg.sh <relpath> | drain" >&2; exit 2;;
  *)
    rel="$1"
    case "$rel" in *..*) echo "refusing path containing '..': $rel" >&2; exit 2;; esac
    p="$inbox/$rel"
    # Gone already = a spent duplicate nudge (the drain or an earlier /agent-msg delivered it).
    # Release any orphan claim and signal exit 3 so the skill ends the turn SILENTLY (no banner).
    [ -f "$p" ] || { rm -f "$claims/$(basename "$rel")" 2>/dev/null; echo "message file gone — duplicate delivery? ($rel)" >&2; exit 3; }
    rp="$(cd "$(dirname "$p")" 2>/dev/null && pwd)/$(basename "$p")"
    case "$rp" in "$inbox"/*) ;; *) echo "refusing path outside inbox: $rp" >&2; exit 2;; esac
    cat "$p"; rm -f "$p"; rm -f "$claims/$(basename "$rel")"   # delivered → release the delivery-claim
    ;;
esac
