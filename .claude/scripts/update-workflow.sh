#!/bin/bash
# update-workflow.sh — pull workflow-machinery updates from the upstream
# claude-workflow clone into THIS consuming repo.
#
# Ships in claude-workflow and propagates to every consuming repo, so each
# project can re-sync the machinery with one command. Running it inside
# claude-workflow itself is a no-op (this IS the source).
#
# WHAT IT SYNCS: the shared machinery tracked under .claude/ in the upstream
#   — agent-roles/, docs/, hooks/, scripts/, the workflow skills/,
#   settings.json.example. The shared workflow docs live under .claude/docs/
#   and sync like any other machinery file (locally-customized copies are
#   flagged, see below).
# WHAT IT LEAVES ALONE (project-owned): the active .claude/settings.json,
#   .claude/workflow.config, .claude/skills/base-test/SKILL.md (project gate
#   commands), the generated .claude/skills/tickets/ skill, and anything you
#   list in WORKFLOW_SYNC_EXCLUDE. Files the consuming repo has *locally
#   customized* are FLAGGED, never clobbered. Project prose (README.md,
#   CLAUDE.md, the project's docs/) is out of scope — reconcile by hand.
#
# Usage:
#   update-workflow.sh                  # sync; report new/updated/skipped/diverged
#   update-workflow.sh --check          # dry-run: report only, write nothing
#   update-workflow.sh --upstream PATH  # override the upstream location
#
# Config (.claude/workflow.config):
#   WORKFLOW_UPSTREAM_PATH   path to the claude-workflow clone (else auto-discovered
#                            as a sibling dir named 'claude-workflow')
#   WORKFLOW_SYNC_EXCLUDE    extra space-separated path globs never to sync
#
# Sync marker: .claude/.workflow-sync records the last-synced upstream short-SHA.
# It lets the script show exactly which upstream commits are landing and tell a
# pristine file (safe to fast-forward) from a locally-customized one (flagged).

set -u

DRY=0
UPSTREAM_OVERRIDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --check|-n) DRY=1 ;;
    --upstream) shift; UPSTREAM_OVERRIDE="${1:-}" ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

REPO="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "not in a git repo" >&2; exit 1; }
CONFIG="$REPO/.claude/workflow.config"
# shellcheck disable=SC1090
[ -r "$CONFIG" ] && . "$CONFIG"

# Resolve upstream: --upstream flag > config > sibling 'claude-workflow'.
UPSTREAM="${UPSTREAM_OVERRIDE:-${WORKFLOW_UPSTREAM_PATH:-}}"
if [ -z "$UPSTREAM" ]; then
  cand="$(dirname "$REPO")/claude-workflow"
  [ -d "$cand/.claude/agent-roles" ] && UPSTREAM="$cand"
fi
if [ -z "$UPSTREAM" ] || [ ! -d "$UPSTREAM/.claude" ]; then
  echo "✗ cannot locate the claude-workflow upstream." >&2
  echo "  Set WORKFLOW_UPSTREAM_PATH in .claude/workflow.config, or pass --upstream <path>." >&2
  exit 1
fi
UPSTREAM="$(cd "$UPSTREAM" && pwd)"

if [ "$UPSTREAM" = "$REPO" ]; then
  echo "This repo IS the upstream (claude-workflow) — nothing to pull."
  exit 0
fi

UP_HEAD="$(git -C "$UPSTREAM" rev-parse --short HEAD 2>/dev/null || echo '?')"
MARKER_FILE="$REPO/.claude/.workflow-sync"
LAST="$(tr -dc 'A-Za-z0-9' < "$MARKER_FILE" 2>/dev/null || true)"

echo "upstream:    $UPSTREAM @ $UP_HEAD"
if [ -n "$LAST" ]; then
  echo "last synced: $LAST"
  if git -C "$UPSTREAM" rev-parse --verify -q "$LAST" >/dev/null 2>&1; then
    echo "── new upstream commits ($LAST..$UP_HEAD) ──"
    git -C "$UPSTREAM" log --oneline "$LAST..HEAD" 2>/dev/null | sed 's/^/  /'
  else
    echo "  (marker '$LAST' not found upstream — divergence detection limited)"
  fi
else
  echo "last synced: (none recorded — first run; differing files will be flagged, not overwritten)"
fi
echo

# Project-owned paths never synced (the consuming repo owns these).
EXCLUDE_DEFAULT=".claude/settings.json .claude/workflow.config .claude/skills/base-test/SKILL.md .claude/skills/tickets .claude/.workflow-sync"
is_excluded() {
  local p="$1" g
  # set -f: the unquoted word-split below must NOT pathname-expand entries like
  # ".claude/skills/define-*" against the caller's cwd. case patterns are
  # unaffected by -f, so glob entries still match.
  set -f
  for g in $EXCLUDE_DEFAULT ${WORKFLOW_SYNC_EXCLUDE:-}; do
    # shellcheck disable=SC2254 — $g is deliberately unquoted: entries may be
    # globs, and a quoted pattern would only ever match literally.
    case "$p" in $g|$g/*) set +f; return 0 ;; esac
  done
  set +f
  return 1
}

# Atomic install: copy src→dst via a temp file + rename, preserving the +x bit.
# Two reasons this matters here:
#   1. Crash-safe — dst is never observed half-written (a kill mid-cp would leave
#      a truncated skill/script).
#   2. SELF-OVERWRITE — this loop syncs .claude/scripts/, which INCLUDES this very
#      file. An in-place `cp` truncates+rewrites dst's inode; when dst is the
#      running script, bash is reading that same inode and silently stops at the
#      shifted offset → only the first N files copied, marker stale, exit 0 (a
#      half-done sync reported as done). rename(2) installs a NEW inode, so the
#      live process keeps executing its original one to completion.
atomic_install() {
  local src="$1" dst="$2" tmp
  mkdir -p "$(dirname "$dst")"
  tmp="$dst.tmp.$$"
  cp "$src" "$tmp" || return 1
  [ -x "$src" ] && chmod +x "$tmp"
  mv -f "$tmp" "$dst"
}

new=(); updated=(); skipped=(); diverged=(); uptodate=0

while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  if is_excluded "$rel"; then skipped+=("$rel"); continue; fi
  src="$UPSTREAM/$rel"; dst="$REPO/$rel"
  [ -f "$src" ] || continue
  if [ ! -f "$dst" ]; then
    new+=("$rel")
    [ "$DRY" = 1 ] || atomic_install "$src" "$dst"
  elif cmp -s "$src" "$dst"; then
    uptodate=$((uptodate + 1))
  elif [ -n "$LAST" ] && git -C "$UPSTREAM" cat-file -e "$LAST:$rel" 2>/dev/null \
       && git -C "$UPSTREAM" show "$LAST:$rel" 2>/dev/null | cmp -s - "$dst"; then
    # Consuming copy matches the last-synced upstream version → pristine, fast-forward.
    updated+=("$rel")
    [ "$DRY" = 1 ] || atomic_install "$src" "$dst"
  else
    diverged+=("$rel")
  fi
done < <(git -C "$UPSTREAM" ls-files -- '.claude/')

report() {
  local label="$1"; shift
  [ "$#" -gt 0 ] || return 0
  printf '%s (%d):\n' "$label" "$#"
  printf '  %s\n' "$@"
}
report "NEW"                                    ${new[@]+"${new[@]}"}
report "UPDATED (fast-forwarded)"               ${updated[@]+"${updated[@]}"}
report "SKIPPED (project-owned)"                ${skipped[@]+"${skipped[@]}"}
report "DIVERGED — locally customized, NOT touched" ${diverged[@]+"${diverged[@]}"}
echo "up-to-date: $uptodate file(s)"

if [ "$DRY" = 1 ]; then
  echo; echo "(--check: nothing written, marker unchanged)"
  exit 0
fi

printf '%s\n' "$UP_HEAD" > "$MARKER_FILE.tmp.$$" && mv -f "$MARKER_FILE.tmp.$$" "$MARKER_FILE"
echo; echo "marker → $UP_HEAD ($MARKER_FILE)"
if [ "${#diverged[@]}" -gt 0 ]; then
  echo "⚠ ${#diverged[@]} diverged file(s) need manual reconciliation (see DIVERGED above)."
fi
echo "Review the working tree (git status / git diff) and commit when satisfied."
