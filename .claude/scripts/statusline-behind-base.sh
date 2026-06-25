#!/bin/bash
# .claude/scripts/statusline-behind-base.sh
#
# ccstatusline `custom-command` widget: prints "⇣ N" = commits this branch is behind
# the LOCAL fleet base branch (time to merge down). Silent (exit 0, no output) when not
# behind, not a git repo, or no base is configured — harmless in non-fleet repos.
#
# Base = WORKFLOW_BASE_BRANCH from the repo's .claude/workflow.config (the shared fleet
# trunk, e.g. `john`/`main`). NB: this is NOT the per-agent recorded branch in
# ~/.claude/agents/<name> — that's the agent's OWN branch, which would give "behind 0".

cat >/dev/null 2>&1 || true   # drain the StatusJSON ccstatusline pipes in (unused)

git rev-parse --git-dir >/dev/null 2>&1 || exit 0
root="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0

base=""
if [ -f "$root/.claude/workflow.config" ]; then
  # shellcheck disable=SC1090
  base="$(. "$root/.claude/workflow.config" 2>/dev/null; printf '%s' "${WORKFLOW_BASE_BRANCH:-}")"
fi
[ -n "$base" ] || exit 0

git rev-parse --verify "$base" >/dev/null 2>&1 || exit 0
behind=$(git rev-list --count "HEAD..$base" 2>/dev/null)
[ "${behind:-0}" -gt 0 ] && printf '⇣ %s' "$behind"
exit 0
