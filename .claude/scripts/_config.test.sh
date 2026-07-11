#!/bin/bash
# Tests for _config.sh — the shared config loader that EVERY hook, script and skill sources.
#
# THE INVARIANT THIS FILE EXISTS FOR: sourcing _config.sh must NEVER fail, in ANY environment.
# It is sourced by scripts that run `set -euo pipefail`, so a non-zero return does not degrade —
# it KILLS the caller, silently, before it prints anything. Live incident (2026-07-11): the
# WORKFLOW_TODO_AGENT block ended with `[ -n "$_self" ] && fleet_agent_id "$_self"`, whose status
# became the subshell's. For anyone whose pane is not a registered agent — every HUMAN, every
# headless run, all of CI — that test is false, the subshell exits 1, and `pnpm docs:dev` died
# with exit 1 and NO output. It worked for the agents, which is why it hid.
#
# So: every row below sources the file in a DEGRADED environment and asserts rc 0 + a usable value.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$here/_config.sh"
[ -f "$SCRIPT" ] || { echo "FATAL: _config.sh not found at $SCRIPT"; exit 1; }
ROOT="$(cd "$here/../.." && pwd)"

pass=0; fail=0
eq(){ if [ "$2" = "$3" ]; then echo "  PASS: $1"; pass=$((pass+1));
      else echo "  FAIL: $1"; echo "        expected: [$2]"; echo "        actual:   [$3]"; fail=$((fail+1)); fi; }

# src <desc> <env...> — source _config.sh under `set -euo pipefail` in the given env; echo rc.
src_rc(){ local rc=0; ( cd "$ROOT" && env "$@" bash -euo pipefail -c "source '$SCRIPT'" ) >/dev/null 2>&1 || rc=$?; printf '%s' "$rc"; }
src_var(){ local var="$1"; shift; ( cd "$ROOT" && env "$@" bash -c "source '$SCRIPT' 2>/dev/null; printf '%s' \"\${$var:-UNSET}\"" ) 2>/dev/null; }

echo "_config.sh — sourcing must never kill a set -e caller"

# A HUMAN's shell: inside tmux, but the pane is not a registered agent. This is the incident.
eq "a non-agent pane (a human's shell): sources cleanly under set -e" "0" "$(src_rc TMUX_PANE=%99999)"
eq "…and WORKFLOW_TODO_AGENT still gets a value (the documented fallback runs)" "1" \
   "$([ "$(src_var WORKFLOW_TODO_AGENT TMUX_PANE=%99999)" != "UNSET" ] && echo 1 || echo 0)"

# Headless: no tmux at all (CI, a cron job, a git hook).
eq "headless (no TMUX/TMUX_PANE): sources cleanly under set -e" "0" "$(src_rc TMUX= TMUX_PANE=)"
eq "…and still yields a WORKFLOW_TODO_AGENT" "1" \
   "$([ "$(src_var WORKFLOW_TODO_AGENT TMUX= TMUX_PANE=)" != "UNSET" ] && echo 1 || echo 0)"

# No agent registry at all (a fresh machine, a clone with no fleet).
eq "no agent registry (fresh machine): sources cleanly under set -e" "0" "$(src_rc HOME=/nonexistent-home-for-tests)"

# An AGENT's pane (the case that always worked) must keep working.
eq "an agent's pane: still sources cleanly" "0" "$(src_rc TMUX_PANE="${TMUX_PANE:-%0}")"

# The knobs every consumer depends on are exported in all of the above.
for v in WORKFLOW_MAIN_PATH WORKFLOW_TODO_AGENT WORKFLOW_FLEET_MODE; do
  eq "$v is set even in a degraded environment" "1" \
     "$([ "$(src_var "$v" TMUX= TMUX_PANE= )" != "UNSET" ] && echo 1 || echo 0)"
done

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
