#!/bin/bash
# Send a message to another registered Claude agent on this machine.
#
# Usage:
#   agent-send.sh <target> "<body>" [--reply|--followup]
#   agent-send.sh <target> --stdin [--reply|--followup]  <<'BODY'
#   ...multi-line body, no escaping needed...
#   BODY
#
# PREFER --stdin/heredoc for any non-trivial body. Passing the body as an argv
# string lets the CALLER's shell expand backticks and $(...) inside it before
# this script ever runs, which silently corrupts messages. A quoted heredoc
# ('BODY') is immune to that.
#
# - Stages <body> in the recipient's mailbox ~/.claude/agent-inbox/<target>/
# - Verifies target agent is alive (PID + tmux pane), pruning stale entries
# - Delivers "/agent-msg <self> <path> [reply|followup]" to target's tmux pane
#
# Kinds: request  (default)            — peer is expected to act and reply
#        reply    (--reply)            — terminal answer, NO response expected
#        followup (--followup)         — a threaded message that DOES expect a
#                                        response (use instead of --reply when
#                                        your "reply" actually asks for action)

set -u

usage() {
  cat >&2 <<'USAGE'
usage: agent-send.sh <target> "<body>" [--reply|--followup]
       agent-send.sh <target> --stdin [--reply|--followup]   # body on stdin (heredoc-safe)
USAGE
  exit 2
}

target="${1:-}"
[ -n "$target" ] && shift || usage

body=""; have_body=0; use_stdin=0; kind=req
while [ "$#" -gt 0 ]; do
  case "$1" in
    --stdin|-)           use_stdin=1 ;;
    --reply|reply)       kind=rep ;;
    --followup|followup) kind=fwd ;;
    --*)                 echo "unknown flag: $1" >&2; usage ;;
    *)                   if [ "$have_body" -eq 0 ]; then body="$1"; have_body=1
                         else echo "unexpected extra arg: $1" >&2; usage; fi ;;
  esac
  shift
done

if [ "$use_stdin" -eq 1 ]; then
  body="$(cat)"
elif [ "$have_body" -eq 0 ]; then
  echo "no message body (pass a quoted body, or --stdin with a heredoc)" >&2
  usage
fi

# Identity works with OR without tmux (DX-jn-8-019): inside tmux the token is the
# pane; headless it's cwd-based. Only the live nudge below needs tmux.
fleet_helper="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/_fleet.sh"
# shellcheck disable=SC1090
[ -r "$fleet_helper" ] && . "$fleet_helper"

# Self-heal: hooks aren't reliable across `claude --resume` paths in
# every Claude Code version, so the registry can drift. Run the
# idempotent registration script first (fast-path no-op if the entry
# is already current) so a stale or missing self-entry is repaired
# before we look ourselves up below.
hook_dir="$(cd "$(dirname "$0")/../hooks" 2>/dev/null && pwd)"
if [ -x "$hook_dir/register-agent.sh" ]; then
  "$hook_dir/register-agent.sh" send-selfheal </dev/null >/dev/null 2>&1 || true
fi

reg="$HOME/.claude/running-agents"
[ -d "$reg" ] || { echo "no registry at $reg" >&2; exit 1; }

# --- Discover self via the identity token (pane in tmux, else cwd-based) ---
shopt -s nullglob
self_name="$(fleet_find_self "$reg" 2>/dev/null || true)"
if [ -z "$self_name" ]; then
  echo "this agent isn't registered (no entry in $reg matches identity token '$(fleet_self_token 2>/dev/null)')" >&2
  exit 1
fi

# --- Locate target ---
target_files=( "$reg/$target".* )
if [ "${#target_files[@]}" -eq 0 ]; then
  echo "no agent named '$target' (active agents: $(ls "$reg" 2>/dev/null | sed 's/\.[0-9]*$//' | sort -u | tr '\n' ' '))" >&2
  exit 1
fi

target_file="${target_files[0]}"
target_pid="${target_file##*.}"
target_pane="$(cat "$target_file" 2>/dev/null)"

# Liveness: claude pid alive?
if ! kill -0 "$target_pid" 2>/dev/null; then
  rm -f "$target_file"
  echo "agent '$target' (pid $target_pid) is gone — pruned stale registry entry" >&2
  exit 1
fi

# Liveness: if the target's token is a tmux pane AND we can drive tmux, the pane
# must still exist (headless targets are keyed by cwd: and rely on the pid check above).
if fleet_tmux_ok 2>/dev/null; then
  case "$target_pane" in
    %*) if ! tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qx "$target_pane"; then
          rm -f "$target_file"
          echo "agent '$target' tmux pane $target_pane is gone — pruned stale registry entry" >&2
          exit 1
        fi ;;
  esac
fi

# --- Stage the message file (per-recipient mailbox) ---
# Messages live under a per-recipient subdir so the recipient's Stop-hook
# inbox drain (.claude/hooks/drain-inbox.sh) can reliably find messages
# addressed to it even when the tmux send-keys nudge below is lost (target
# mid-turn, in a permission prompt, scrolled back, etc). The filename encodes
# sender + kind (req|rep|fwd) so the drain can reconstruct the exact
# `/agent-msg <sender> <path> [reply|followup]` command. Sanitized agent names
# never contain dots, so `.` is an unambiguous field delimiter.
inbox="$HOME/.claude/agent-inbox"
recipient_dir="$inbox/$target"
mkdir -p "$recipient_dir"
msg_id="$(uuidgen | tr -d - | tr 'A-Z' 'a-z')"
msg_name="$msg_id.$self_name.$kind.txt"
rel_path="$target/$msg_name"
printf '%s' "$body" > "$recipient_dir/$msg_name"

# --- Deliver (best-effort nudge) ---
# The body is already durably staged above; this send-keys only controls
# latency. If it's lost, the recipient drains the message on its next Stop.
case "$kind" in
  rep) wire_kw="reply" ;;
  fwd) wire_kw="followup" ;;
  *)   wire_kw="" ;;
esac
slash="/agent-msg $self_name $rel_path"
[ -n "$wire_kw" ] && slash="$slash $wire_kw"

# Idle-guard: skip the live nudge when it would be wasted or harmful, and let
# the recipient's Stop-drain deliver from the durable file instead:
#   - pane in copy-mode (scrolled back): the nudge lands in copy-mode and is lost.
#   - target busy mid-turn (fresh agent-busy marker, set by mark-busy.sh on the
#     target's UserPromptSubmit and re-touched on its every PreToolUse, so it
#     covers notification/continuation turns too): the nudge would only buffer and replay as a
#     DUPLICATE after the drain already delivered at the target's Stop. Skipping
#     it costs no latency — a busy agent can't act before its Stop anyway — and
#     eliminates the duplicate. The marker is cleared on the target's Stop.
# The live nudge needs tmux AND a pane-keyed target. Without either (no tmux, or a
# headless cwd-keyed target), there's no terminal to inject into — the message is
# already durably staged, so it drains at the target's next turn (DX-jn-8-019).
if ! fleet_tmux_ok 2>/dev/null || [ "${target_pane#%}" = "$target_pane" ]; then
  nudge="queued (no tmux nudge available) — drain delivers at target's next turn"
else
  pane_in_mode="$(tmux display-message -p -t "$target_pane" '#{pane_in_mode}' 2>/dev/null || echo 0)"
  busy_marker="$HOME/.claude/agent-busy/$target"
  target_busy=0
  # A marker older than 5 min is treated as stale (a turn that crashed OR was interrupted without
  # clearing) so we never suppress the nudge forever; a fresher marker means busy.
  [ -f "$busy_marker" ] && [ -n "$(find "$busy_marker" -mmin -5 2>/dev/null)" ] && target_busy=1

  if [ "$pane_in_mode" = "1" ]; then
    nudge="nudge skipped (pane scrolled/in copy-mode) — drain will deliver"
  elif [ "$target_busy" = "1" ]; then
    nudge="nudge skipped (target busy mid-turn) — drain delivers at its next Stop"
  else
    # Delivery claim FIRST — BEFORE the send-keys. This live nudge now OWNS delivery of this
    # message; the target's Stop-drain skips a fresh-claimed file so it won't ALSO inject it (the
    # buffered /agent-msg would otherwise fire after the drain already delivered → a "file gone"
    # duplicate). Claiming before the send-keys closes the gap where a Stop-drain could fire between
    # the nudge and the claim and still double-deliver. A stale claim (>2min: nudge lost / long turn)
    # is reclaimed by the drain, so the worst case is a short delay, never a lost message. Cleared on
    # delivery by agent-msg.sh.
    mkdir -p "$HOME/.claude/agent-nudge-claim" 2>/dev/null || true
    : > "$HOME/.claude/agent-nudge-claim/$(basename "$rel_path")" 2>/dev/null || true
    # -l = literal; sends the slash command into the target's prompt buffer.
    tmux send-keys -t "$target_pane" -l "$slash"
    tmux send-keys -t "$target_pane" Enter
    nudge="nudged"
  fi
fi

echo "sent to $target as $self_name (msg=$rel_path kind=$kind; $nudge)"
