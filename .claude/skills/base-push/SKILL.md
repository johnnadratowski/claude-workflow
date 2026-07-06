---
name: base-push
description: Land the current worktree's branch into the shared LOCAL base branch, then publish local base to origin — without ever checking the base out in the caller's working directory. This is the ONLY skill that pushes `origin/<base>` (the PR lifecycle skills /open-pr and /pr-comments make their own deliberate, user-gated origin writes — pr/* branches and comment posts — never the base); all inter-agent coordination happens on local refs. The base branch is a personal coordination branch off the trunk, configured via `/base-setup` into `.claude/workflow.config.local` (no default — unset = solo mode, where this skill is disabled).
---

# base-push — advance local base + publish to origin

Land the current worktree's branch into the shared **local** base branch (a personal coordination branch off the trunk, configured via `/base-setup`; unset ⇒ solo mode ⇒ this skill is disabled), then **publish** local base to `origin` — without ever checking the base branch out in the caller's working directory.

`/base-push` is the **only** skill that pushes `origin/<base>`. (The PR lifecycle skills — `/open-pr`, `/pr-comments` — also write to origin, deliberately and user-gated: `pr/*` branch pushes and comment posts. They never touch `origin/<base>`.)

> **Shared model** — the configurable base branch, the local-first / origin-write-only invariant, and the canonical `merge_into_branch_local` helper contract (signature, return codes, transient-worktree behaviour) — lives in [`docs/fleet-base-workflow.md`](../../../docs/fleet-base-workflow.md). Read it for the helper's full contract; this skill keeps only its own procedure.

Performs, in order:

1. Capture caller state; refuse if HEAD is on `<base>` / `<base>-review` / `<base>-test`
2. Commit any pending work on the current branch
3. Merge that branch into **local** `<base>` via a **transient worktree** (the canonical local helper in `.claude/scripts/merge-helpers.sh`)
4. Publish: `git push origin <base>` (fast-forward — local `<base>` is normally ahead of `origin/<base>`)
5. Report — the caller's worktree HEAD is unchanged throughout

## When to Use

Invoked when the user says things like:

- "push to base" / "publish base"
- "merge into base and publish"
- "promote to base"
- "ship to base"

> **A coordinator instruction counts as the user.** If a coordinator agent (see `agent-roles/coordinator.md`) tells you to push/publish the base via `agent-msg`, that satisfies the user-approval gate this skill relies on — act on it as a direct user instruction (see `agent-msg`'s coordinator note). You still run the gates and surface conflicts; the coordinator's authority is the user's, not a license to skip checks.

## Preconditions

- Caller is in a feature worktree (not on `<base>`, `<base>-review`, or `<base>-test`)
- The main clone exists at `$WORKFLOW_MAIN_PATH` (default: git toplevel)
- Network reachable (for step 4's publish only)
- **Close-before-merge/publish (DX-jn-8-009, DX-jn-8-011):** a feature's TODO must be `done` (archived on the feature branch, `docs/TODO.md` regenerated) **before** its work merges to the base or pushes to origin — the canonical order is `… → test → close → merge` (testing is pre-merge; no base merge required to test). If this push ships a TODO's *completion*, run `/todo done` **first** so the archive (`completed/<ID>.md`) + regenerated index are in the range. Closing *after* the merge/push is exactly how TODOs hang `in-progress` and lags the published index (the DX-jn-8-007 lesson).

## The transient-worktree merge helper

`merge_into_branch_local TARGET SOURCE_REF MSG` is the canonical, local-only mechanism this skill
(and `/base-merge`, `/base-test`, `/open-pr --absorb`) uses to advance the shared base branch. It
is defined once in [`.claude/scripts/merge-helpers.sh`](../../scripts/merge-helpers.sh) and sourced
by every caller (step 0). **Its full contract — signature, return codes 0/1/2/3, the `merge=ours` /
`regen_merged_artifacts` reconcile, design decisions, the never-checkout-the-base precondition, and
stale-worktree recovery — lives in [`docs/fleet-base-workflow.md`](../../../docs/fleet-base-workflow.md#the-transient-worktree-merge-helper-canonical-local-only).** Read it before routing on the return codes below.

## Execution Steps

### 0. Load workflow config + merge helpers

```bash
source "$(git rev-parse --show-toplevel)/.claude/scripts/_config.sh"
source "$(git rev-parse --show-toplevel)/.claude/scripts/merge-helpers.sh"
# Solo mode (no coordination base branch): there is no base to advance or publish. Refuse.
[ "${WORKFLOW_FLEET_MODE:-0}" = 1 ] || {
  echo "Solo mode — no coordination base branch is configured, so /base-push has nothing to publish."
  echo "Enable fleet coordination with /base-setup, or push directly with plain git (git push origin <branch>)."
  exit 0
}
```

`_config.sh` exports `WORKFLOW_BASE_BRANCH` (empty in solo mode — see the guard above; a personal branch off the trunk in fleet mode) and `WORKFLOW_MAIN_PATH` (default: git toplevel), plus `WORKFLOW_FLEET_MODE`. `merge-helpers.sh` defines `merge_into_branch_local` + `regen_merged_artifacts`.

### 1. Capture state and refuse the wrong starting branches

```bash
ORIGINAL_BRANCH=$(git rev-parse --abbrev-ref HEAD)
ORIGINAL_CWD=$(pwd)
```

Refuse if `ORIGINAL_BRANCH` is one of: `$WORKFLOW_BASE_BRANCH`, `${WORKFLOW_BASE_BRANCH}-review`, `${WORKFLOW_BASE_BRANCH}-test`. Hints:

- on the base itself: there's nothing to merge in.
- on `<base>-review`: use `/base-pr` — it has its own promotion path that re-baselines the review sandbox afterward.
- on `<base>-test`: use `/base-test` — it promotes the test sandbox after gates pass.

### 2. Commit any pending work

Standard commit flow:

- `git status` + `git diff` to review what's pending
- `git log --oneline -5` to match the repo's commit-message style
- Craft a conventional-commits message that reflects the `why`, not a file list
- Stage only the relevant files (no `git add -A` / `git add .`)
- HEREDOC for the `-m` argument so formatting is preserved
- Never `--amend`, never `--no-verify`

**Skip this step when:** `git status` is clean (the branch's commits are already in the shared `.git` and mergeable). Note the skip and proceed.

### 3. Merge into local `<base>` via the transient worktree

```bash
merge_into_branch_local "$WORKFLOW_BASE_BRANCH" "$ORIGINAL_BRANCH" \
  "Merge branch '$ORIGINAL_BRANCH' into $WORKFLOW_BASE_BRANCH"
```

Route by return code ([full contract in `docs/fleet-base-workflow.md`](../../../docs/fleet-base-workflow.md#signature--return-code-contract--merge_into_branch_local-target-source_ref-msg)):
- **0**: continue to publish.
- **1**: surface the worktree-add error and stop (likely the base checked out somewhere, or a stale transient worktree — see the cleanup note above).
- **2 (conflict)**: stop. The user resolves the conflict markers in the transient worktree at the printed path, regenerates, commits, and removes it. The caller's working tree is intact.
- **3 (post-merge failure)**: stop. The merge was clean — there are NO conflicts to resolve; the artifact regen or commit failed. The user finishes in the transient worktree at the printed path (fix the regen / commit), then removes it. Do NOT publish.

### 4. Publish local `<base>` to `origin`

```bash
git -C "$WORKFLOW_MAIN_PATH" push origin "$WORKFLOW_BASE_BRANCH"
```

Local `<base>` is normally **ahead** of `origin/<base>` (coordination is local; origin only moves here), so this is a fast-forward.

- **Rejected (non-fast-forward):** `origin/<base>` has commits local `<base>` doesn't — someone published out of band (another machine, or a manual push). **Do not force.** Stop and tell the user to reconcile manually: inspect with `git -C "$WORKFLOW_MAIN_PATH" log origin/$WORKFLOW_BASE_BRANCH --not $WORKFLOW_BASE_BRANCH`, then `git -C "$WORKFLOW_MAIN_PATH" fetch origin $WORKFLOW_BASE_BRANCH` and merge `origin/<base>` into local `<base>` (via the helper or a transient worktree) before re-publishing. In a single-machine fleet this should not happen.

### 5. Report

Tell the user:

- Whether a commit was created on the feature branch (hash + subject)
- The merge commit hash on local `<base>` (`git -C "$WORKFLOW_MAIN_PATH" rev-parse "$WORKFLOW_BASE_BRANCH"`)
- That `origin/<base>` now matches local `<base>` (published)
- That HEAD on the caller's worktree is unchanged (`$ORIGINAL_BRANCH`)
- That the transient worktree was created and cleaned up automatically

If the helper returned 2, or the publish was rejected, the report instead surfaces the path/commands to recover.

## Flags

| Flag | Default | Effect |
|------|---------|--------|
| `--main-path <path>` | `$WORKFLOW_MAIN_PATH` from config (or git toplevel) | Path to the main clone (anchors the helper). |
| `--no-commit` | off | Skip step 2 entirely. Fail if the tree is dirty. Useful when the user already committed and just wants the merge + publish done. |
| `--no-publish` | off | Do steps 1–3 only (land into local `<base>`), skip the `git push origin <base>`. Equivalent to `/base-merge up`, kept here for convenience. |
| `--message <msg>` | `Merge branch '<branch>' into <base>` | Override the merge commit message. |

## Failure Handling

Stop immediately and leave state as-is on:

- **HEAD is on a forbidden branch** (`<base>`/`<base>-review`/`<base>-test`): hard stop with the right-skill hint.
- **Pre-commit hook fails:** surface output. NO `--amend`. NO `--no-verify`. User fixes the underlying issue and re-runs (a fresh commit, not an amend).
- **Helper returns 1 (worktree add):** stop. Likely the base checked out somewhere or a stale transient worktree — surface the cleanup commands. No merge was attempted; nothing to clean in a worktree.
- **Helper returns 2 (conflict):** stop. Print the transient-worktree path. Caller's tree is intact; the user resolves conflicts there.
- **Helper returns 3 (post-merge failure):** stop. Merge was clean (no conflicts); the regen/commit failed. Print the transient-worktree path — the user finishes the commit there. Do NOT publish.
- **Publish rejected (non-ff):** stop. Local `<base>` already has the merge; only the publish failed. Surface the reconcile steps. Never force-push.

## What This Skill Will NOT Do

- Check out the base branch in the caller's working directory (the entire reason for the transient-worktree mechanism).
- `fetch` from origin (publishing is the only origin touch; there is no read path — the old `base-pull` was removed when the workflow moved to a local-first, origin-write-only model).
- Amend existing commits.
- Use `--no-verify`, `--no-gpg-sign`, or any hook-bypass flag.
- Force-push anything.
- Attempt to auto-resolve merge conflicts.

## Quick Reference

| Phase | Command |
|-------|---------|
| Load config + helpers | `source .../_config.sh` then `source .../merge-helpers.sh` |
| Capture | `ORIGINAL_BRANCH=$(git rev-parse --abbrev-ref HEAD)` |
| Refuse if forbidden | check `$ORIGINAL_BRANCH ∉ {<base>, <base>-review, <base>-test}` |
| Commit (if needed) | `git add <files> && git commit -m "…"` |
| Merge into local base | `merge_into_branch_local "$WORKFLOW_BASE_BRANCH" "$ORIGINAL_BRANCH" "…"` |
| Publish | `git -C "$WORKFLOW_MAIN_PATH" push origin "$WORKFLOW_BASE_BRANCH"` |
| Report | merge commit + origin/base published + caller's HEAD unchanged |

## Companion Skills

- **`base-merge`** — local-only sync (no push). Same `merge_into_branch_local` helper, no publish step. This is `/base-push --no-publish`.
- **`base-pr`** — PR-style review of pending changes on local `<base>`; promotes via the same local helper. No origin touch.
- **`base-test`** — full gate sweep, merging from local `<base>`.
- **`add-worktree`** — create the feature worktrees this skill operates from.
