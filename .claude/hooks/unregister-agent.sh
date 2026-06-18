#!/bin/bash
# SessionEnd hook — removes this Claude session from ~/.claude/running-agents.
# Best-effort cleanup; senders also prune stale entries on send (PID-not-alive
# check), so this hook missing or failing isn't load-bearing.

set -u

cat >/dev/null 2>&1 || true

# Hook runs as a direct child of claude, so $PPID is the claude pid.
# Remove any registry file whose filename ends in .<PPID>.
shopt -s nullglob 2>/dev/null || true
for f in "$HOME/.claude/running-agents/"*."$PPID"; do
  bn="$(basename "$f")"
  rm -f "$HOME/.claude/agent-busy/${bn%.*}"   # clear the busy marker too
  rm -f "$f"
done

# --- Non-blocking work-loss warning on session end (best-effort) ---
# The most relevant exit-time loss surface: ending a session with uncommitted
# changes, or with commits that never landed in the LOCAL base branch, gets no
# warning anywhere else. Surface it (stderr) so nothing is silently stranded.
# Always exits 0; any git/array edge case is swallowed. (Local-base, not origin:
# origin/<base> is frozen + advanced only by /base-push — "not in local base" is
# the real "unlanded" signal, mirroring remove-worktree's gate.)
repo="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || true)}"
if [ -n "$repo" ] && git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
  base=""
  cfg="$repo/.claude/scripts/_config.sh"
  [ -r "$cfg" ] && base="$( . "$cfg" >/dev/null 2>&1; printf '%s' "${WORKFLOW_BASE_BRANCH:-}" )"
  warns=()
  dirty="$(git -C "$repo" status --porcelain 2>/dev/null || true)"
  [ -n "$dirty" ] && warns+=("uncommitted changes ($(printf '%s\n' "$dirty" | grep -c . || true) file(s))")
  branch="$(git -C "$repo" branch --show-current 2>/dev/null || true)"
  if [ -n "$base" ] && [ -n "$branch" ] && [ "$branch" != "$base" ] \
     && git -C "$repo" rev-parse --verify "$base" >/dev/null 2>&1; then
    ahead="$(git -C "$repo" rev-list --count "$base..HEAD" 2>/dev/null || echo 0)"
    [ "${ahead:-0}" -gt 0 ] 2>/dev/null \
      && warns+=("$ahead commit(s) on '$branch' not yet in local '$base' (unlanded)")
  fi
  if [ "${#warns[@]}" -gt 0 ]; then
    {
      printf '\n[session-end] ⚠ possible unsaved work in %s:\n' "$repo"
      for w in "${warns[@]}"; do printf '  - %s\n' "$w"; done
      printf '  Commit, /base-merge, or /base-push as appropriate so nothing is lost.\n'
    } >&2
  fi
fi

exit 0
