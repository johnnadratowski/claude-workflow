---
name: base-push
description: Land the current worktree's branch into the shared LOCAL base branch, then publish local base to origin — without ever checking the base out in the caller's working directory. This is the ONLY skill that pushes `origin/<base>` (the PR lifecycle skills /open-pr and /pr-comments make their own deliberate, user-gated origin writes — pr/* branches and comment posts — never the base); all inter-agent coordination happens on local refs. Base branch is configurable via `.claude/workflow.config` (default `main`).
---

# base-push — advance local base + publish to origin

Land the current worktree's branch into the shared **local** base branch (default `main`), then **publish** local base to `origin` — without ever checking the base branch out in the caller's working directory.

`/base-push` is the **only** skill that pushes `origin/<base>`. (The PR lifecycle skills — `/open-pr`, `/pr-comments` — also write to origin, deliberately and user-gated: `pr/*` branch pushes and comment posts. They never touch `origin/<base>`.) All inter-agent coordination happens on the **local** `refs/heads/<base>` ref (shared across every worktree on this machine); `origin/<base>` is just a published snapshot that advances when — and only when — you run this skill.

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

## The transient-worktree merge helper (canonical, local-only)

This is the canonical mechanism every skill uses to advance the shared base branch — `/base-push`, `/base-merge` (up), `/base-test` (its pre-test base merge), `/base-pr` (promotion), and `/open-pr` (`--absorb`). It is defined ONCE in **`.claude/scripts/merge-helpers.sh`** and **sourced** by every caller — source it alongside `_config.sh`:

```bash
source "$(git rev-parse --show-toplevel)/.claude/scripts/merge-helpers.sh"
```

(Previously these functions lived inline here as prose-only code blocks, which meant `/base-test` — which calls `regen_merged_artifacts` but never sourced this skill — hit `command not found` mid-merge. The single sourced script removes that whole class of drift.)

It is **purely local** — no `fetch`, no `push`. `origin` is never touched inside the helper; publishing is a separate explicit step that only `/base-push` performs. Because all worktrees share one `.git`, a `LOCAL_SOURCE` branch committed in any worktree is visible as a local ref — no push is needed to make a peer's work mergeable (commit it; don't push it). `TARGET` must NOT be checked out in any worktree (that single constraint also acts as a natural mutex, serializing merges into `TARGET`).

### Return-code contract — `merge_into_branch_local TARGET SOURCE_REF MSG`

Every caller MUST route on these. **The conflict (2) vs post-merge-failure (3) split is load-bearing** — they used to be a single overloaded `2`, so a clean merge whose regen failed told the user to "resolve conflicts" that didn't exist and look for a path that was never printed.

| Code | Meaning | Worktree | What the caller does |
| ---- | ------- | -------- | -------------------- |
| `0` | success; local `TARGET` advanced | cleaned up | continue |
| `1` | setup / `worktree add` failure — **no merge attempted** | none left (a dangling registration is self-healed via `git worktree prune`) | stop; surface (base checked out elsewhere, or a stale transient worktree — cleanup note below) |
| `2` | **merge conflict** | **preserved at printed path** (markers) | stop; the user resolves there, regenerates, commits, removes |
| `3` | **post-merge failure** — merge was CLEAN but regen or commit failed | **preserved at printed path** (already merged) | stop; the user fixes the regen/commit there, commits, removes — there is nothing to "resolve" |

`regen_merged_artifacts WT` (also defined by the script) reconciles the `merge=ours` artifacts on the materialized merged tree and stages them so they fold into the merge commit: `docs/TODO.md` + back-links (pure-node, so it works even in a bare transient worktree with no project dependencies installed). It returns non-zero on failure, which the helper maps to code `3`. A consuming repo with ADDITIONAL `merge=ours` generated artifacts forks `merge-helpers.sh`, adds its own regen there, and excludes the fork from `update-workflow` sync (`WORKFLOW_SYNC_EXCLUDE`).

Design decisions baked into the helper:

- **`LOCAL_SOURCE` is a local branch, never `origin/<branch>`.** Coordination is purely local; a peer's work is mergeable as soon as it's *committed* (shared `.git`), with no push required.
- **The merge commit lands on `refs/heads/TARGET` directly** because the transient worktree is branch-attached (no `--detach`). The caller's own worktree HEAD is never touched.
- **`--no-ff` is mandatory.** Matches the repo's merge topology.
- **`--no-commit` then regenerate then commit.** Generated artifacts (`docs/TODO.md`) are `merge=ours` in `.gitattributes` — a merge keeps the current branch's stale copy rather than conflicting. `regen_merged_artifacts` rebuilds `docs/TODO.md` on the materialized tree and folds it into the merge commit, so the committed index is correct and the drift-guard passes. Every auto-committing merge path (this helper, `/base-merge` down, `/base-test`'s base merge) MUST run that reconcile — see the helper's doc comment. (The `merge=ours` driver must be registered per clone — `git config merge.ours.driver true`, via `.claude/scripts/setup-git-merge-drivers.sh`; otherwise the merge falls back to a normal, possibly-conflicting one — safe.)
- **Conflicts leave the transient worktree intact** at a printed path — the failure mode is "an extra directory to resolve," never "the caller's tree is mid-conflict."
- **No `origin` inside the helper.** Publishing is `/base-push`'s separate final step.

> **Precondition:** `<target>` is not checked out in any worktree. For `<base>` / `<base>-review` / `<base>-test` this is the project convention. For an unusual `--base` passed to `/base-pr`, verify the base isn't checked out first.
>
> **Only a checkout of the TARGET branch breaks this** — a worktree on any *other* branch (a coordinator worktree on a dedicated `<base>-cc` branch, or detached at `origin/<base>`) is harmless. Never check out the literal base branch in a worktree: it makes `worktree add <base>` fail here, silently breaking the merge path for every agent. Ride a `<base>-cc` branch or a detached ref for a base-tracking worktree — see `add-worktree`.
>
> **Stale transient worktree (return 1 after a crash):** if a previous merge crashed mid-flight it may have left a worktree attached to the base, blocking everyone. Recover with `git -C "$WORKFLOW_MAIN_PATH" worktree list` to find the `wf-merge-local-*` path, then `git -C "$WORKFLOW_MAIN_PATH" worktree remove --force <path>` (and `git worktree prune`).

## Execution Steps

### 0. Load workflow config + merge helpers

```bash
source "$(git rev-parse --show-toplevel)/.claude/scripts/_config.sh"
source "$(git rev-parse --show-toplevel)/.claude/scripts/merge-helpers.sh"
```

`_config.sh` exports `WORKFLOW_BASE_BRANCH` (default `main`) and `WORKFLOW_MAIN_PATH` (default: git toplevel). `merge-helpers.sh` defines `merge_into_branch_local` + `regen_merged_artifacts`.

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

Route by return code (full contract above):
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

---

**Skill Version**: 1.1.0
**Category**: Git Workflow

## Changelog

- **1.1.0** — (merge-helper hardening) `merge_into_branch_local` +
  `regen_merged_artifacts` are now **extracted into `.claude/scripts/merge-helpers.sh`**
  and sourced (step 0) instead of living inline here as prose — every caller now
  shares one definition (fixes `/base-test`/`/base-pr` calling them with no
  definition in scope). The return-code contract is **de-overloaded**: `2` is now
  conflict-only, `3` is a post-merge regen/commit failure (both preserve the
  transient worktree and print its path + recovery commands). Step 3 + Failure
  Handling route code `3`.
