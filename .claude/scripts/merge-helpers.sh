#!/usr/bin/env bash
# merge-helpers.sh — the canonical transient-worktree merge helpers for the
# fleet workflow. SOURCE this file (it only defines functions; sourcing it has
# no side effects and sets no shell options):
#
#   source "$(git rev-parse --show-toplevel)/.claude/scripts/merge-helpers.sh"
#
# Defines:
#   merge_into_branch_local TARGET SOURCE_REF MSG   — advance local refs/heads/TARGET
#   regen_merged_artifacts  WT                       — reconcile merge=ours artifacts
#
# Used by /base-push, /base-merge (up + down), /base-test (step 2), /base-pr
# (promotion), and /open-pr (--absorb). Defined once here and sourced by every
# caller, so a caller can never call them with no definition in scope.
#
# ── Return-code contract (merge_into_branch_local) ───────────────────────────
#   0 — success; local TARGET advanced, transient worktree cleaned up
#   1 — setup / worktree-add failure: NO merge was attempted. The error is
#       printed, and `git worktree prune` is run so a dangling registration left
#       by a previously-crashed merge is self-healed (a re-run then succeeds).
#   2 — MERGE CONFLICT: transient worktree PRESERVED at the printed path with
#       conflict markers — resolve, regenerate, commit, then `worktree remove`.
#   3 — POST-MERGE failure: the merge was CLEAN (no conflicts), but the artifact
#       regeneration or the commit failed. Transient worktree PRESERVED at the
#       printed path (already merged, nothing to "resolve") — fix the regen /
#       commit there, then `worktree remove`.
#
# Codes 2 and 3 were a single overloaded `2` before this split: a clean merge
# whose regen failed used to return 2 with no path printed, so the caller told
# the user to "resolve conflicts" that didn't exist and hunt for a path that was
# never emitted. They are distinct now, and every worktree-preserving path
# prints its path + the exact recovery commands.

merge_into_branch_local() {
  local TARGET="$1" SOURCE_REF="$2" MSG="$3"
  local MAIN_PATH="${WORKFLOW_MAIN_PATH:-$(git rev-parse --show-toplevel)}"
  local TMP_PARENT TMP_WT
  TMP_PARENT="$(mktemp -d -t wf-merge-local-XXXX)"
  TMP_WT="$TMP_PARENT/wt"

  git -C "$MAIN_PATH" rev-parse --verify "refs/heads/$TARGET" >/dev/null 2>&1 \
    || git -C "$MAIN_PATH" branch "$TARGET" "refs/remotes/origin/$TARGET" 2>/dev/null \
    || { echo "Local '$TARGET' missing and no origin/$TARGET to seed it from."; rm -rf "$TMP_PARENT"; return 1; }

  if ! git -C "$MAIN_PATH" worktree add "$TMP_WT" "$TARGET" 2>&1; then
    echo "Worktree add failed — is '$TARGET' checked out somewhere, or is a stale"
    echo "transient worktree on '$TARGET' lingering from a crashed merge?"
    rm -rf "$TMP_PARENT"
    # Self-heal a dangling .git/worktrees/<name> registration left by a crashed
    # merge whose /tmp dir was already cleaned (prune only removes registrations
    # whose working dir is gone — it never touches a live checkout, so a TARGET
    # genuinely checked out elsewhere is left intact and still surfaced below).
    git -C "$MAIN_PATH" worktree prune
    git -C "$MAIN_PATH" worktree list >&2
    return 1
  fi

  if ! git -C "$TMP_WT" merge --no-commit --no-ff "$SOURCE_REF"; then
    echo "MERGE CONFLICT in transient worktree at:"
    echo "  $TMP_WT"
    echo "Resolve the conflicts there, regenerate (node .claude/scripts/gen-todos.mjs), commit, then:"
    echo "  git -C \"$MAIN_PATH\" worktree remove \"$TMP_WT\""
    return 2
  fi

  if git -C "$TMP_WT" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
    if ! regen_merged_artifacts "$TMP_WT"; then
      echo "POST-MERGE artifact regeneration FAILED (the merge itself was clean — no conflicts)."
      echo "Transient worktree preserved at:"
      echo "  $TMP_WT"
      echo "Finish manually: fix the regeneration there, commit, then:"
      echo "  git -C \"$MAIN_PATH\" worktree remove \"$TMP_WT\""
      return 3
    fi
    if ! git -C "$TMP_WT" commit --no-edit -m "$MSG"; then
      echo "POST-MERGE commit FAILED (the merge was clean, artifacts are staged)."
      echo "Transient worktree preserved at:"
      echo "  $TMP_WT"
      echo "Finish manually: commit there, then:"
      echo "  git -C \"$MAIN_PATH\" worktree remove \"$TMP_WT\""
      return 3
    fi
  fi

  git -C "$MAIN_PATH" worktree remove "$TMP_WT"
  rm -rf "$TMP_PARENT"
  return 0
}

# regen_merged_artifacts WORKTREE
#
# Reconcile the merge=ours generated artifacts on an already-merged, NOT-yet-
# committed tree and stage them so they land IN the merge commit. Call AFTER a
# successful `git merge --no-commit` and BEFORE the commit, from every
# auto-committing merge path.
#
# This generic version regenerates docs/TODO.md (+ back-links) only — pure-node,
# so it runs in a bare transient worktree with no node_modules. A consuming repo
# with ADDITIONAL merge=ours generated artifacts (e.g. a role-permissions SQL
# seed regenerated from a TS matrix) forks this script, adds its regen here, and
# excludes the fork from update-workflow sync (WORKFLOW_SYNC_EXCLUDE) — see the
# goals-onchain consumer, whose fork also regenerates its role_permissions seed.
#
# Returns 0 on success, non-zero on failure (callers map that to code 3).
regen_merged_artifacts() {
  local WT="$1"
  ( cd "$WT" && node .claude/scripts/gen-todos.mjs ) || return 1
  git -C "$WT" add docs/TODO.md docs/todos
}
