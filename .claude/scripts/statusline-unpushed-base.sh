#!/bin/bash
# .claude/scripts/statusline-unpushed-base.sh
#
# ccstatusline `custom-command` widget: prints "⇡ N" = commits the LOCAL fleet base
# branch is AHEAD of its published snapshot origin/<base> (unpublished work awaiting a
# human-gated /base-push). Partner to statusline-behind-base.sh's "⇣ N". Silent
# (exit 0, no output) when nothing is unpublished, origin/<base> is unknown, or this
# isn't a fleet repo — harmless anywhere.
#
# Base = WORKFLOW_BASE_BRANCH from the repo's .claude/workflow.config. Read-only, no
# network: it compares the LOCAL base ref against the CACHED origin/<base> ref (the
# fleet never fetches — origin only advances on an explicit /base-push).

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
git rev-parse --verify "origin/$base" >/dev/null 2>&1 || exit 0

ahead=$(git rev-list --count "origin/$base..$base" 2>/dev/null)
[ "${ahead:-0}" -gt 0 ] && printf '⇡ %s' "$ahead"
exit 0
