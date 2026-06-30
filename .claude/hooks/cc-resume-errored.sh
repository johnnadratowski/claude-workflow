#!/bin/bash
# Stop hook — COORDINATOR ONLY: sweep the fleet for errored agents (StopFailure marker)
# and nudge each "continue". Automatic recovery for the common rate-limit case: an
# agent that StopFailured is stopped at its prompt (alive) but won't self-resume, and a
# stale busy marker (now cleared by mark-error.sh) had been suppressing peers' nudges.
# Every time the coordinator stops, it resumes any stuck peers.
#
# No-op for non-coordinator agents (this runs in every agent's Stop chain but gates on
# role == coordinator). Marker-based detection (per the user's call): an agent whose
# session predates the StopFailure hook writes no marker and is NOT covered until it
# merges-down + restarts — a known blind spot, accepted.
#
# Throttled per-agent (default 2 min, WORKFLOW_RESUME_THROTTLE_MIN) so frequent CC stops
# don't spam, and a still-rate-limited agent is retried at a sane cadence rather than
# hammered. Needs tmux. Silent, always exits 0 (never blocks the coordinator's Stop).

set -u
cat >/dev/null 2>&1 || true   # drain hook stdin

reg="$HOME/.claude/running-agents"
[ -d "$reg" ] || exit 0
errdir="$HOME/.claude/agent-error"
[ -d "$errdir" ] || exit 0
command -v tmux >/dev/null 2>&1 || exit 0

hook_dir="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
# shellcheck disable=SC1090
[ -r "$hook_dir/../scripts/_fleet.sh" ] && . "$hook_dir/../scripts/_fleet.sh"
self_name="$(fleet_find_self "$reg" 2>/dev/null || true)"
[ -n "$self_name" ] || exit 0

# Coordinator-only. Role: explicit override file, else name pattern (keep in sync with
# resolve_role()/role_of()/statusline-role.sh).
role=""
[ -f "$HOME/.claude/agents/$self_name.role" ] && role="$(tr -dc 'A-Za-z0-9_-' < "$HOME/.claude/agents/$self_name.role")"
if [ -z "$role" ]; then
  case "$self_name" in
    cc|coordinator|*-cc|*-coordinator|*-coordinator-*|coordinator-*) role=coordinator ;;
    *) role=other ;;
  esac
fi
[ "$role" = coordinator ] || exit 0

throttle_dir="$HOME/.claude/agent-nudged"
mkdir -p "$throttle_dir"
throttle_min="${WORKFLOW_RESUME_THROTTLE_MIN:-2}"
msg="Continue — the API rate limit should have cleared. Resume where you left off."

shopt -s nullglob
for ef in "$errdir"/*; do
  [ -f "$ef" ] || continue
  name="$(basename "$ef")"
  [ "$name" = "$self_name" ] && continue                       # never nudge self
  rf=( "$reg/$name".* ); [ "${#rf[@]}" -gt 0 ] || continue     # must be registered
  pid="${rf[0]##*.}"; pane="$(cat "${rf[0]}" 2>/dev/null)"
  case "$pane" in %*) ;; *) continue ;; esac                   # need a tmux pane to nudge
  command -v fleet_alive >/dev/null 2>&1 && { fleet_alive "$pid" "$pane" || continue; }
  tf="$throttle_dir/$name"                                     # throttle: skip if nudged recently
  [ -f "$tf" ] && [ -n "$(find "$tf" -mmin "-$throttle_min" 2>/dev/null)" ] && continue
  [ "$(tmux display-message -p -t "$pane" '#{pane_in_mode}' 2>/dev/null || echo 0)" = "1" ] && continue  # copy-mode → lost
  tmux send-keys -t "$pane" -l "$msg" 2>/dev/null
  tmux send-keys -t "$pane" Enter 2>/dev/null
  : > "$tf"
done
exit 0
