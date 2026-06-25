#!/bin/bash
# .claude/scripts/statusline-role.sh
#
# ccstatusline `custom-command` widget: prints a compact fleet-identity badge for THIS
# pane — "<role>·L<lane>" (e.g. "cc·L8", "feat·L2") so each worktree's terminal is
# identifiable at a glance. Falls back to just "<role>" when no lane is known. Silent
# (exit 0, no output) when this worktree isn't a registered fleet agent.
#
# Self is identified by matching $PWD against the ~/.claude/agents/<name>.cwd sidecars
# (tmux-independent, same mechanism as statusline-unread.sh). Role comes from a
# ~/.claude/agents/<name>.role override, else the name pattern (matches resolve_role in
# register-agent.sh / role_of in agent-fanout.sh). Lane comes from
# ~/.config/goals-worktrees.json (worktree path → lane).

cat >/dev/null 2>&1 || true   # drain the StatusJSON ccstatusline pipes in (unused)

shopt -s nullglob
self=""
for f in "$HOME"/.claude/agents/*.cwd; do
  [ "$(cat "$f" 2>/dev/null)" = "$PWD" ] && { self="$(basename "$f" .cwd)"; break; }
done
[ -n "$self" ] || exit 0

# Role: explicit override file, else derive from the name (keep patterns in sync with
# resolve_role()/role_of()).
role=""
[ -f "$HOME/.claude/agents/$self.role" ] && role="$(tr -dc 'A-Za-z0-9_-' < "$HOME/.claude/agents/$self.role")"
if [ -z "$role" ]; then
  case "$self" in
    cc|coordinator|*-cc|*-coordinator|*-coordinator-*|coordinator-*) role=coordinator ;;
    test|*-test|*-test-*|test-*)                                     role=test ;;
    review|pr|*-pr|*-pr-*|pr-*|*-review|*-review-*|review-*)          role=review ;;
    *)                                                               role=feature ;;
  esac
fi

# Short label.
case "$role" in
  coordinator) label=cc ;;
  feature)     label=feat ;;
  review)      label=rev ;;
  test)        label=test ;;
  *)           label="$role" ;;
esac

# Lane (best-effort; blank if unavailable). Two sources, in priority order:
#   1. config-driven — WORKFLOW_TODO_LANE / WORKFLOW_LANE in .claude/workflow.config[.local]
#   2. a path→lane worktrees registry (e.g. goals' ~/.config/goals-worktrees.json)
lane=""
root="$(git rev-parse --show-toplevel 2>/dev/null)"
if [ -n "$root" ] && [ -f "$root/.claude/workflow.config" ]; then
  # shellcheck disable=SC1090
  lane="$(. "$root/.claude/workflow.config" 2>/dev/null; . "$root/.claude/workflow.config.local" 2>/dev/null; printf '%s' "${WORKFLOW_TODO_LANE:-${WORKFLOW_LANE:-}}")"
fi
if [ -z "$lane" ] && [ -n "$root" ] && [ -r "$HOME/.config/goals-worktrees.json" ] && command -v python3 >/dev/null 2>&1; then
  lane="$(python3 -c "import json
try:
    d=json.load(open('$HOME/.config/goals-worktrees.json'))
    print(next((w.get('lane','') for w in d.get('worktrees',[]) if w.get('path')=='$root'),''))
except Exception: pass" 2>/dev/null)"
fi

if [ -n "$lane" ]; then printf '%s·L%s' "$label" "$lane"; else printf '%s' "$label"; fi
exit 0
