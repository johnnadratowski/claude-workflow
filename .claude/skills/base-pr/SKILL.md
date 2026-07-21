---
name: base-pr
description: Review what's new on the LOCAL base branch since the last review. Resolves the range from the WORKFLOW_REVIEW_BRANCH anchor (default <base>-review — a branch POINTER, never checked out), spawns the reviewer subagent (mode 2) on it, and advances the anchor on GREEN LIGHT. --pr <n> reviews a GitHub PR read-only the same way. Reports findings; applying fixes is the caller's normal /todo flow.
---

# base-pr — review what's new on the base branch

PR-style review of **what's new on a base branch since the last review**. The base
defaults to the configured `$WORKFLOW_BASE_BRANCH`; `--base <branch>` reviews any other
shared branch. The audit itself is the [`reviewer`](../../agents/reviewer.md) definition
— this skill only resolves the range, spawns it, and advances the anchor.

**The anchor:** `WORKFLOW_REVIEW_BRANCH` (default `<base>-review`) is a **branch
pointer** marking where the base stood at the last GREEN review. It is **never checked
out** — `/base-push` and `/base-merge` still reserve the name (refuse to operate on it),
but no worktree ever sits on it. One anchor per base (`${BASE}-review`), so `--base`
derives its own.

## Invocation

```
/base-pr                       # review <anchor>..<base>, advance the anchor on GREEN
/base-pr --base <branch>       # same flow against another shared branch
/base-pr --no-advance          # review only; leave the anchor where it is
/base-pr --pr <number>         # review a GitHub PR (read-only, reports in terminal)
```

## Procedure (local range mode)

1. **Resolve config + refuse solo:**
   ```bash
   source "$(git rev-parse --show-toplevel)/.claude/scripts/_config.sh"
   [ "${WORKFLOW_FLEET_MODE:-0}" = 1 ] || { echo "Solo mode — no base branch. Spawn the reviewer directly (mode 2) on a range instead."; exit 0; }
   BASE="${BASE:-$WORKFLOW_BASE_BRANCH}"
   ANCHOR="${WORKFLOW_REVIEW_BRANCH:-${BASE}-review}"
   git rev-parse --verify "$BASE" >/dev/null || exit 1   # base must exist locally
   git rev-parse --verify "$ANCHOR" >/dev/null 2>&1 || git branch "$ANCHOR" "$BASE"  # first run: anchor at base, nothing to review
   ```
2. **Resolve the range** (purely local — no fetch): `git log --no-merges --oneline
   $ANCHOR..$BASE`. Empty ⇒ "nothing new to review", stop. Anchor diverged from the base
   (not an ancestor) ⇒ surface `git log --left-right --oneline $ANCHOR...$BASE` and ask.
   Report upfront: N commits, M files; note unpublished commits
   (`git log --oneline origin/$BASE..$BASE`, cached ref) so the user knows the audit
   includes pre-publication work.
3. **Spawn the reviewer** — Agent tool, `subagent_type: reviewer`, **mode 2
   (range/bundle)**: the range `$ANCHOR..$BASE`, the pin SHA (`git rev-parse $BASE`),
   and any context the caller supplied. Model from `WORKFLOW_REVIEW_MODEL_B` (the single-reviewer / stronger knob, default `sonnet`; empty ⇒
   omit ⇒ inherit). The definition owns the entire audit (corpus, dimensions A–E,
   nemesis escalation, verdict tokens).
4. **Relay the verdict** to the user (and `agent-send --reply` to the requester if a
   peer dispatched this). Findings are **reported, not fixed here** — fixes belong to
   their authors' normal `/todo` flow (or a TODO minted for them).
5. **Advance the anchor on GREEN LIGHT** (skip with `--no-advance`):
   ```bash
   git branch -f "$ANCHOR" "$BASE"   # pointer move only — nothing is checked out
   ```
   NOT GREEN ⇒ leave the anchor: the next run re-reviews the same range plus whatever
   landed since (findings stay in view until resolved or explicitly waved through by the
   user, who can advance manually with the same command).

## Mode: review a GitHub PR (`--pr <number>`)

Read-only; ignores `--base`; never touches the anchor; never posts to GitHub.
Prereq: `gh` authenticated.

1. `gh pr view <n> --json number,title,body,author,baseRefName,headRefName,additions,deletions,changedFiles,url`
   and `gh pr diff <n>` — report the PR upfront (title, author, size).
2. **Spawn the reviewer** — mode 2 with the **PR number + body + the diff artifact
   inline** (the reviewer's isolation worktree can also run `gh pr diff` itself; inline
   guards against auth differences). Deep review (gates against the PR head) is the
   caller's business: `gh pr checkout` in a scratch worktree, then spawn the tester there.
3. **Relay the verdict in the terminal** as a recommendation to the human
   (approve / request-changes / comment) — never posted to GitHub. Reply to the
   requester if peer-dispatched.

## What this skill will NOT do

- Check out any branch, apply fixes, promote, merge, push, or fetch.
- Advance the anchor past a NOT-GREEN review (that requires the user's explicit call).
- Post anything to GitHub in `--pr` mode.

## Companions

- **[`reviewer`](../../agents/reviewer.md)** — owns the audit methodology + verdicts.
- **[`base-push`](../base-push/SKILL.md)** / **[`base-merge`](../base-merge/SKILL.md)** —
  reserve the anchor name; publishing/landing stays with them.
- **[`base-test`](../base-test/SKILL.md)** — the test counterpart (tester spawn recipe).

---

**Skill Version**: 2.0.0
**Category**: Code Review / Git Workflow

_Version history: see [CHANGELOG.md](./CHANGELOG.md)._
