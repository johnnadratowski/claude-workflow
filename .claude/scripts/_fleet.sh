#!/bin/bash
# Shared fleet identity/liveness helpers (DX-jn-8-019). Source-only.
#
# The fleet keys each agent by an IDENTITY TOKEN so it works with OR without tmux:
#   - inside tmux  → the token is $TMUX_PANE (e.g. "%3")
#   - headless     → the token is "cwd:<absolute-cwd>" (one agent per worktree here)
# The registry file ~/.claude/running-agents/<name>.<pid> stores this token; self-id
# matches it; liveness is pid-based, with a tmux pane-check only when the token is a pane.
#
# This makes tmux OPTIONAL: registration, self-identification, mailbox delivery/drain,
# busy-marking and status all work headless. Only live remote-drive (send-keys nudge,
# restart, compact, rename) needs tmux — callers gate those on fleet_tmux_ok and skip
# gracefully when it's absent.

# Identity token for THIS process.
fleet_self_token() {
  if [ -n "${TMUX_PANE:-}" ]; then printf '%s' "$TMUX_PANE"; else printf 'cwd:%s' "$PWD"; fi
}

# True when tmux can actually be driven (inside a pane AND the binary exists).
fleet_tmux_ok() { [ -n "${TMUX_PANE:-}" ] && command -v tmux >/dev/null 2>&1; }

# fleet_alive <pid> <token> — pid must be alive; if the token is a tmux pane, the pane
# must still exist (best-effort — a missing tmux binary doesn't fail a pane token, since
# we can't disprove liveness without it).
fleet_alive() {
  kill -0 "$1" 2>/dev/null || return 1
  case "$2" in
    %*) command -v tmux >/dev/null 2>&1 && ! tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qx "$2" && return 1 ;;
  esac
  return 0
}

# fleet_find_self <registry-dir> — echo the name whose registry entry matches our token.
fleet_find_self() {
  local d="$1" tok f; tok="$(fleet_self_token)"
  for f in "$d"/*; do
    [ -f "$f" ] || continue
    [ "$(cat "$f" 2>/dev/null)" = "$tok" ] && { basename "$f" | sed 's/\.[0-9]*$//'; return 0; }
  done
  return 1
}
