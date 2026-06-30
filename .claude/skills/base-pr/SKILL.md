---
name: base-pr
description: PR-style review of what's new on the LOCAL base branch since the last review, on a dedicated review branch. base-pr switches the worktree to a reserved review snapshot (WORKFLOW_REVIEW_BRANCH, default <base>-review) — never a feature branch — diffs it against local `<base>`, audits (design / security / doc-drift / integration-contracts) against the project doc corpus, optionally applies fixes and promotes into local `<base>` via the local merge helper, then re-anchors the snapshot. No fetch, no push. Base branch configurable via `.claude/workflow.config` (default `main`).
---

# base-pr — review then promote (local-first)

PR-style review of **what's new on a base branch since the last review**. The base branch defaults to `$WORKFLOW_BASE_BRANCH`; pass `--base <branch>` to review against any other shared branch.

`/base-pr` operates on a **dedicated review branch** — `WORKFLOW_REVIEW_BRANCH` (default `<base>-review`), a reserved baseline snapshot it checks out (creating it at local `<base>` if absent). The snapshot marks where the base stood at the last review; `/base-pr` diffs it against the current **local `<base>`** to surface everything that has landed since, and treats those new commits as the pull request under review. **It never reviews from — or promotes — a feature branch** (that would push unreviewed work into the base; see step 1).

> **Why local, not `origin/<base>`?** Coordination is purely local — local `<base>` is the source of truth, and `origin/<base>` is only a published snapshot that advances on an explicit `/base-push`. Sourcing the audit range from `origin/<base>` would make unpublished local commits invisible — they'd slip past the review until published. Operating on the local ref means any commit on `<base>` is in scope the moment it exists. This skill never fetches or pushes.

Runs in the current worktree, but always on the **dedicated review branch**: invoke it from anywhere — if the tree is clean it switches to (or creates) `<base>-review` first; if you have uncommitted changes it refuses, so a feature branch's in-progress work is never swept into the base. This makes real the `<base>-review` reservation that `/base-push` and `/base-merge` already enforce.

> **One review branch per base, automatically.** The review branch is derived per-base (`${BASE}-review`), so `--base other-branch` reviews on `other-branch-review` while the default base reviews on `<base>-review` — they can't re-anchor onto each other. Override the name with `WORKFLOW_REVIEW_BRANCH` if needed.

Performs, in order:

1. Resolve the base branch + the dedicated review branch (`<base>-review`); get the worktree onto it — switch/create if clean, refuse if mid-work — so a feature branch is never reviewed-from or promoted
2. Resolve the review range `HEAD..<base>` from **local** `<base>` (no fetch), produce the diff
3. Read the design corpus (`docs/` + every relevant `CLAUDE.md`) and run the structured audit (design / security / doc-drift / integration-contracts), escalating to the `nemesis` adversarial deep-audit when the diff touches a high-risk surface
4. Show the findings; open a plan letting the user pick which to address
5. Merge local `<base>` into the current branch — this advances the snapshot and gives a base to apply fixes on
6. Apply the accepted fixes, run per-project gates, then **STOP for the user's review of the uncommitted fixes** — the human-in-the-loop gate: commit only after the user has had a chance to review (monocle / `git diff`). **If the Monocle engine is live** (`.claude/scripts/monocle-review.sh available`), offer `/monocle-review diff <ID>` — Monocle reviews the uncommitted diff natively while the skill attaches the TODO + plan as context (stable ids), then blocks on the verdict; engine down ⇒ `git diff` as before. (`/afk` is the only exception.)
7. Commit the fixes on the current branch
8. Ask the user to confirm, then promote the fixes into **local** `<base>` via the local merge helper from `base-push` (no push — publishing is a later explicit `/base-push`)
9. Fast-forward the branch onto the now-current local `<base>` so it's a clean snapshot for the next review

## Invocation

```
/base-pr                     # review what's new on local <base>, then fix + promote (local)
/base-pr --base other-branch  # same flow, but against local other-branch
/base-pr --no-fix             # review only: show findings and stop (snapshot left untouched)
/base-pr --pr <number>        # review a GitHub PR (read-only); report findings in the terminal
```

`--base` and `--no-fix` compose. `--pr` is a distinct **read-only GitHub mode** (see below) —
it ignores `--base`, never touches local `<base>`, and never writes to GitHub.

## Mode: review a GitHub PR (`--pr <number>`)

A **read-only** audit of an open GitHub pull request whose findings are reported **in the
terminal** (and replied to the requester if a peer dispatched it via `agent-send`). It does
**not** post to GitHub, touch local `<base>`, apply fixes, or promote — it's a review for a
human to read and act on. Runs only the corpus-load + audit (steps 4–5), then reports (step 12).

**Prerequisite:** the `gh` CLI installed + authenticated (`gh auth status`). Read-only here —
only `gh pr view` / `gh pr diff` (+ an optional `gh pr checkout` into a transient worktree if
you want to run gates); nothing is posted. (Projects preferring an MCP can swap a GitHub MCP's
read tools for the `gh` calls — same flow.)

1. **Resolve the PR + capture the diff:** `gh pr view <number> --json
   number,title,body,author,baseRefName,headRefName,additions,deletions,changedFiles,url,files`
   for metadata; `gh pr diff <number>` for the patch. Report the PR upfront; summarize large
   diffs per-file (don't truncate silently).
2. **Load the corpus** (step 4) and **run the audit** (step 5: design/best-practices, security,
   doc-drift incl. architecture, nemesis on high-risk), citing `file:line` from the PR diff.
3. **Report in the terminal** (step 12's shape): findings by category + severity, whether
   nemesis ran, and an overall recommendation (approve / request-changes / comment) **as a
   recommendation to the human** — do NOT post it. If a peer dispatched this, reply the summary
   with `agent-send <requester> --stdin --reply`.

Nothing below this section (snapshot merge, fixes, promotion, re-anchor) runs for `--pr`.

## When to Use

Invoked when the user says things like:

- "review base" / "base pr" / "review the pr"
- "review what's new on base" / "review what's new on `<branch>`"
- "audit base"

> **A coordinator instruction counts as the user.** If a coordinator agent (see `agent-roles/coordinator.md`) tells you to review or promote via `agent-msg`, treat it as a direct user instruction (see `agent-msg`'s coordinator note) — including the step-8 "ask the user to confirm" before promotion: a coordinator directive to promote IS that confirmation. You still run the pre-flight checks and surface anything unsafe.

## Preconditions

- The current worktree is on the dedicated review branch (`<base>-review`), OR has a clean tree so base-pr can switch to it. Uncommitted changes on another branch → hard stop (base-pr won't promote a feature branch's unreviewed work).
- The base branch exists **locally** (`git rev-parse --verify "$BASE"` succeeds). Origin is never queried — review and promotion are both purely local.
- A readable `docs/` tree and at least a root `CLAUDE.md` (for the audit corpus).

## Execution Steps

### 0. Load workflow config

```bash
source "$(git rev-parse --show-toplevel)/.claude/scripts/_config.sh"
source "$(git rev-parse --show-toplevel)/.claude/scripts/merge-helpers.sh"   # merge_into_branch_local (step 10 promotion)
BASE="${BASE:-$WORKFLOW_BASE_BRANCH}"      # overridden by --base <branch>
# The DEDICATED review branch — a reserved snapshot base-pr owns, derived per-base
# (so --base picks its own), env-overridable via WORKFLOW_REVIEW_BRANCH.
REVIEW_BRANCH="${WORKFLOW_REVIEW_BRANCH:-${BASE}-review}"
```

### 1. Capture state + get onto the dedicated review branch

```bash
ORIGINAL_CWD=$(pwd)
```

Verify `$BASE` resolves locally (`git rev-parse --verify "$BASE"`); if not, stop.

**Get onto the dedicated review branch before anything destructive.** base-pr must NOT run on a feature branch: its promotion (step 10) merges the *current* branch into local `<base>`, so on a feature branch it would push that branch's **unreviewed** commits into the base (the review only audits `HEAD..$BASE` — the base's new commits — never your work). The review branch is `<base>-review`, the reserved snapshot `/base-push` and `/base-merge` already refuse and point here:

```bash
CURRENT=$(git rev-parse --abbrev-ref HEAD)
if [ "$CURRENT" != "$REVIEW_BRANCH" ]; then
  if [ -n "$(git status --porcelain)" ]; then
    echo "base-pr runs on the dedicated review branch '$REVIEW_BRANCH', but you're on '$CURRENT'"
    echo "with uncommitted changes. Commit/stash, then switch (git checkout $REVIEW_BRANCH) — or run"
    echo "from the review worktree. Refusing, so unreviewed work on '$CURRENT' is never promoted into $BASE."
    exit 1
  fi
  if git rev-parse --verify "$REVIEW_BRANCH" >/dev/null 2>&1; then
    git checkout "$REVIEW_BRANCH"
  else
    git checkout -b "$REVIEW_BRANCH" "$BASE"   # fresh snapshot anchored at local <base>
  fi
fi
BRANCH="$REVIEW_BRANCH"   # everything below reviews / promotes / re-anchors THIS branch
```

`$REVIEW_BRANCH` is `<base>-review` (distinct from `<base>`/`master`/`main`), so the never-checkout-the-literal-base rule always holds. A freshly created review branch sits AT `<base>`, so step 2's `HEAD..$BASE` is empty → "nothing new to review" (correct for a first run).

Verify `$BASE` resolves locally (`git rev-parse --verify "$BASE"`); if not, stop — the base branch doesn't exist locally. (Recovery if the user expected it: `git fetch origin && git branch <base> origin/<base>` — but the skill shouldn't auto-create it.)

### 2. Resolve the review range (local — no fetch)

The audit range comes entirely from **local** `<base>`. No `git fetch`: coordination is purely local, so local `<base>` is the source of truth.

```bash
git log --no-merges --oneline HEAD..$BASE     # new commits on the base since the snapshot
git diff --stat HEAD...$BASE                  # three-dot: diff from the merge base
```

`HEAD..$BASE` (two-dot) lists the new base-branch commits. `HEAD...$BASE` (three-dot) diffs from the merge base, so anything the snapshot branch carries that the base lacks is excluded — the patch shows only what the base added.

Topology checks:

- If `git log HEAD..$BASE` is empty: local `<base>` has not advanced past the snapshot. Nothing new to review — stop with that message.
- If the snapshot branch is *ahead* of / diverged from local `<base>`: unusual — a prior promotion may not have completed, or the snapshot is anchored to a different base. Surface `git log --left-right --oneline HEAD...$BASE` and ask the user.
- Normal case (snapshot is an ancestor of local `<base>`): proceed.

**Note unpublished work if any:** check `git log --oneline origin/$BASE..$BASE` (read-only, against the cached `origin/<base>` ref — no fetch) — if non-empty, local `<base>` has commits not yet published. Mention this in the upfront report so the user knows the audit includes pre-publication work.

**Report the range back to the user upfront** ("Reviewing what's landed on local `<base>` since the `<branch>` snapshot — N commits, M files changed; K of those unpublished [if applicable]") before the deeper audit starts.

### 3. Capture the diff

```bash
git log --no-merges --pretty=format:'%h %s%n%b%n---' HEAD..$BASE
git diff HEAD...$BASE   # full patch — feed this into the audit
```

For very large diffs (thousands of lines), summarize per-file before drilling in. Don't truncate silently — tell the user when the diff is bigger than what fits comfortably.

### 4. Load the design + rules corpus

**Tier 1 — Best-practices docs (canonical "how we do it"). ALWAYS load in full when the diff touches the matching area.** These are the primary reference for the audit — every diff is judged against them first.

- `docs/best-practices.md` — the project's coding conventions, scenario-organized (each section names a problem, states the rule, gives a recipe). The audit walks each scenario whose surface is touched by the diff and checks the diff follows the recipe (see step 5.A).
- Projects that split best-practices per area (e.g. `docs/best-practices/backend.md`, `docs/frontend-coding-standards.md`, `docs/contracts-best-practices.md`) — load the ones the diff touches.

If a best-practices doc *doesn't exist* for an area the diff touches heavily, that itself is a doc-drift finding (the area needs one).

**Tier 2 — Project rules + design corpus. Always read what's relevant.**

- `CLAUDE.md` (root) and every nested `*/CLAUDE.md` whose area is touched by the diff
- `docs/architecture.md` (and any `docs/architecture/*.md` topic docs), `docs/product.md`
- `docs/security.md` / `docs/security/*.md` (**always** — the security pass is mandatory every run)
- `docs/api-conventions.md` (if the project exposes an API), `docs/testing.md`
- Anything under `docs/` whose filename matches files/areas in the diff (use `grep -l` over `docs/` for the changed module names)

If a referenced doc doesn't exist, log it as a doc-drift finding.

### 5. Run the audit

Produce three sections — write them to the user AND keep them as working notes for the plan step.

**A. Design alignment** — primary lens: best-practices docs (Tier 1 from step 4)

The best-practices docs are scenario-organized: each scenario names a real failure mode, states the rule that prevents it, and gives a recipe. They are the canonical "this is how we do it." The audit's first responsibility is to judge the diff against them.

**A.1 — Walk every Tier 1 scenario whose surface the diff touches.** For each one, ask:
- Does the diff follow the rule + recipe? If not, this is a Design finding. Reference the scenario by name and the file:line of the violating code; quote the specific rule sentence from the doc that the code breaks. Severity: blocker / nit / question.
- If the doc names a **single egress point** (a wrapper every call must go through — e.g. an HTTP client wrapper, a notification helper, a DB-access layer), grep the diff for any bare alternative that bypasses it. A bypass of a documented single-egress point is always a finding.
- If the doc gives a recipe (a numbered list, "How to apply"), check each step against the diff. Missing a step is a finding.

**A.2 — Other design / rules checks** (still important, not best-practices-doc-driven):
- Cross-project / module-boundary rules from `CLAUDE.md` or `docs/architecture.md`.
- Conventional Commits.
- Framework conventions the project documents.
- Anything in `docs/architecture.md` / `docs/product.md` whose surface the diff touches — including **architectural invariants** the diff must not break.

**A.3 — Coverage gap: new patterns the doc should capture.** Best-practices docs evolve with the code. If the diff introduces a pattern that's *correct* — done well, would survive review — but isn't yet documented in the relevant best-practices doc and ought to be, that's a recommendation, not a code change. Examples of "ought to be":
- A new single egress point for an external service.
- A new convention for a recurring problem (a novel idempotency pattern, a new auth tier, a new way of structuring a state machine).
- A new "never do X" rule the diff codifies by removing every instance of X.
- A novel resolution for a class of bug the doc doesn't yet name.

Capture these as **Best-practices coverage gap findings** — file:line of the new pattern, what it does, suggested doc location. These are recommendations to the doc author, not blockers on the code.

Flag findings as **Design findings**, each with: file:line, what changed, which scenario / doc / rule / invariant it conflicts with (or which gap it surfaces), severity (blocker / nit / question / coverage-gap).

**B. Security audit** (mandatory — every run)

Walk the diff with:
- OWASP top-10 surface: SQL/NoSQL injection, XSS, command injection, SSRF, path traversal, deserialization, IDOR, broken access control
- Authn/authz: any new route or query that bypasses the project's permission model
- Secrets: any value that looks like a key/token/password/JWT secret/webhook URL committed in plaintext
- Server-side validation at trust boundaries (per `docs/security.md`)
- Any project-specific sensitive surface `docs/security.md` flags (payment/money movement, approval flows, signer thresholds, multi-factor gates, etc.)
- New external calls — env-gated config, properly authenticated, timeout/retry bounded?
- Test coverage of the security-sensitive change

Flag findings as **Security findings**, each with: file:line, the concern, exploitability (high / medium / low / theoretical), recommended fix.

**C. Doc-drift checklist** — verifies the implementer's documentation-sync step (`docs/doc-sync.md`, if the project has one) was actually done.

For each code area changed, ask:
- **Product-behavior drift (primary):** Does this diff change *how the product functions* — a flow, rule, limit, default, edge-case, or business decision — without the **product docs** being updated to encode it? An **unencoded product/business decision is a doc-drift finding** even if no existing doc was made untrue. (Conversely, a product doc section the diff made untrue is also a finding.)
- **Architecture drift:** Did this diff add/remove a component, change a dependency or data flow, introduce or break an **architectural invariant**, or change the system topology — without `docs/architecture.md` (or the relevant `docs/architecture/*.md` topic doc) being updated? An architecture change shipped without the architecture doc reconciled is a doc-drift finding. Cross-check every component name, data-flow description, and invariant in the sections the diff touches.
- **Best-practices accuracy:** Does any Tier 1 best-practices doc now contain a claim the diff makes untrue? Renamed function, moved file, removed scenario, changed signature, deleted egress point, replaced recipe step — these are the easy misses. Cross-check every concrete file path, function name, and code example in the scenarios touching the diff's surface (never synthesize an API name from memory; verify against code).
- Did an API change without the API docs (e.g. swagger/OpenAPI annotations + regenerated spec) being updated? (Only if the project exposes an API.)
- Did a new env var, port, config knob, or migration land without `CLAUDE.md` / the relevant doc being updated?
- Did a security-sensitive surface change without `docs/security.md` being updated?
- Was a TODO addressed without being closed in the TODO system?

The **best-practices coverage gaps** identified in A.3 are also doc-drift in the broader sense — list them again here as concrete "consider adding scenario X to docs/<file>.md" recommendations if they didn't already get a Design finding.

List every doc that appears stale and what specifically needs to change.

**D. Adversarial deep-audit (nemesis) — conditional**

The A–C passes are a manual walk. When the diff touches a **high-risk surface**, escalate to a full adversarial audit by invoking the **`nemesis-auditor`** skill (via the Skill tool). It runs the Feynman + State-Inconsistency auditors in an iterative back-and-forth loop and writes verified findings.

Trigger nemesis when the diff touches any of:

- **Value movement** — transfers, withdrawals, deposits, balances, payments
- **Coupled state mutated across multiple writes**, or a finalizer/cron/queue that resumes after a crash
- **Multi-step state machines** — auth, approval flows, signer-count gates
- **Smart contracts** (if applicable) — any on-chain logic change
- **Event/indexer handlers** — idempotency / coupled-entity updates
- **Anything that crosses a trust boundary** (user input → privileged operation)

Scope the nemesis run to the changed files/functions named in the diff — it's an iterative, PoC-writing audit, so don't point it at the whole repo. Skip it entirely for docs-only, UI-copy, config, or test-only diffs; the A–C walk is sufficient there.

Fold every nemesis **verified** finding into the **Security findings** list with its id and discovery path. Note in the report whether nemesis ran or was skipped, and why.

**E. Integration-contract audit**

If the diff calls an **external API, RPC, or third-party provider**, verify the **operations it uses** are actually correct — **re-check independently; do not assume the implementer/planner got it right** (this dimension exists because contract bugs slip past planning). For each integration the diff touches:

- **Were the operations verified against authoritative docs?** Cross-check `docs/integration-notes.md` **and** the provider's own docs (the provider's doc tool first — its documentation MCP if one exists, else `context7` for libraries). **Explore the docs yourself** — a missing or hand-wavy verification is a finding.
- **Is the note fresh enough?** ≤30 days may be trusted; older without a re-verify is a finding. **Money-movement / state-mutating operations must be re-verified every time regardless of age.**
- **Was `integration-notes.md` updated in the same diff?** A newly used operation not recorded (with date + doc source), or a new doc location not added to the provider's _Doc sources_ → doc-drift finding.
- **No authoritative docs?** Confirm the implementer asked the user and/or reverse-engineered **only in sandbox/testnet** (never prod, never money-moving) with dated findings recorded. An unverified contract on a money-movement surface is a **blocker** — worst case, flag it for a sandbox reverse-engineering pass rather than letting it land.

### 6. Show findings + open the fix plan

Write the three audit sections to the user, then use the plan tooling (EnterPlanMode → ExitPlanMode) to present a numbered plan that:
- Restates each finding as a discrete fix item (Design — including A.1 violations + A.3 coverage-gap recommendations / Security — including any nemesis findings / Doc-drift / Integration-contract sections)
- Marks severity / blocker status (coverage-gap recommendations are never blockers)
- Asks the user which items to fix in this pass — and whether to roll best-practices/architecture doc updates into the same fix commit or a separate doc-only one

Wait for user input. Items the user defers should be captured as a note (the user may want them tracked as TODOs).

If `--no-fix` was passed: skip steps 7–11 and end here with the findings + deferred-findings summary. The snapshot branch is left untouched.

### 7. Merge local `<base>` into the snapshot branch

Bring the snapshot up to the current base — this advances the baseline and gives a clean base to apply fixes on:

```bash
git status --porcelain   # must be clean
git merge "$BASE"
```

- If the tree is dirty: surface `git status` and ask the user to commit/stash first — do not auto-stash.
- If the merge conflicts: stop. Surface the conflicted files and let the user resolve. Do not auto-resolve.
- Normal case (snapshot is an ancestor of local `<base>`): this fast-forwards cleanly.

### 8. Apply accepted fixes

Apply fixes via Edit / file operations on the current branch. Run per-project gates as you go (the same gates `/base-test` runs — lint, type-check, unit tests, build, any drift guards for the touched area). Re-run codegen + drift checks if you edited a generated source.

Do **NOT** run destructive admin/DB commands without explicit user permission — they can wipe local state shared across worktrees.

### 9. Pause for user review, then commit the fixes

Surface `git status` and `git diff`. Ask the user to confirm before committing. If they want changes, iterate. Do not commit without explicit approval.

On approval:

- Conventional Commits subject + body focused on the *why*
- HEREDOC for the message
- Stage specific files (no `git add -A` / `git add .`)
- `git commit` (NEW commit — never `--amend`)

Pre-commit hook fails: surface output, no `--amend`, no `--no-verify`. User resolves and re-runs with a fresh commit.

If the user accepted no fixes (review was clean, or every finding deferred): skip steps 9–10 entirely and go to step 11 to leave the snapshot advanced to the current base.

### 10. Ask to merge the fixes into the base branch (local-only)

Promotion is **purely local** — it merges the review/fix branch into the **local** base branch via `merge_into_branch_local`; nothing is fetched or pushed. Publishing the base to `origin`, if ever wanted, is a separate explicit `/base-push` the user runs later.

Ask the user to confirm promotion. On approval:

```bash
merge_into_branch_local "$BASE" "$BRANCH" \
  "Merge branch '$BRANCH' (base-pr review fixes) into $BASE"
```

The helper is sourced from [`.claude/scripts/merge-helpers.sh`](../../scripts/merge-helpers.sh) (step 0). It advances **local** `<base>` in a short-lived transient worktree (no fetch, no push), so the base is never checked out in the current worktree. Because all worktrees share one `.git`, the local `$BRANCH` is mergeable as-is — no push needed. Route by return code (full contract in the helper script):

- **0**: success — local `<base>` now includes the fix commit; continue to step 11.
- **1**: worktree-add failure — `<base>` is checked out somewhere, or a stale transient worktree lingers. Surface the error + cleanup commands, stop. No merge was attempted.
- **2 (conflict)**: stop. Surface the printed transient-worktree path so the user can resolve the conflict markers, commit, and clean up manually. The fixes are safe on the local `$BRANCH` regardless.
- **3 (post-merge failure)**: stop. The merge was clean — no conflicts; the artifact regen or commit failed. Surface the printed transient-worktree path so the user can finish the commit there. The fixes are safe on the local `$BRANCH` regardless.

### 11. Re-anchor the snapshot for the next review

Step 10 advanced **local** `<base>` to include the fix commit. Fast-forward the snapshot branch onto the now-current local `<base>` so it exactly marks the just-reviewed state — the next `/base-pr` then reviews only what lands after this point:

```bash
git merge --ff-only "$BASE"    # FF snapshot to the now-advanced local <base>
```

`--ff-only` is non-destructive: if it can't fast-forward, it no-ops with an error to surface — do NOT `reset --hard` or force; the promotion already succeeded.

### 12. Report

- The base branch, the snapshot branch, and the range (`<snapshot-sha>..<base>`, N commits, M files, and K unpublished if local was ahead of origin)
- A short summary of findings by category (counts + blocker count)
- Whether the nemesis deep-audit ran (with its finding count) or was skipped, and why
- Which findings were fixed vs deferred
- The fix commit on the branch (hash + subject), if any
- The merge commit on **local** `<base>`, if promoted (and a reminder that it's unpublished — `/base-push` to publish when ready)
- That the snapshot branch is now re-anchored to local `<base>`
- Which branch the worktree is on (`$BRANCH` = the review branch). **If step 1 switched here from another branch**, say so and how to return: "switched to `<base>-review` for the review — you started on `<CURRENT>`; `git checkout <CURRENT>` to go back."

If `--no-fix` was passed, the report ends at the findings + deferred-findings summary and notes the snapshot is unchanged.

## Flags

| Flag | Default | Effect |
|------|---------|--------|
| `--base <branch>` | `$WORKFLOW_BASE_BRANCH` | Base branch to review against and promote into. |
| `--no-fix` | off | Run the audit and present the plan, then stop. Do NOT merge the base in, apply, commit, promote, or re-anchor. |
| `--pr <number>` | off | **Read-only GitHub mode** (see "Mode: review a GitHub PR"). Source the diff from `gh pr diff <number>`, audit, report findings in the terminal. Ignores `--base`; never touches local `<base>`; never posts to GitHub. |
| `--main-path <path>` | `$WORKFLOW_MAIN_PATH` | Helper's anchor (for the transient-worktree promotion). |

## Failure Handling

Stop immediately and leave state as-is on:

- **On another branch with uncommitted changes:** hard stop — base-pr won't promote a feature branch's unreviewed work; commit/stash and switch to the review branch (or run from the review worktree). On a *clean* tree it switches to/creates `<base>-review` automatically, so being on the base / `master` / a feature branch is fine as long as the tree is clean.
- **Base branch missing locally:** stop — `git rev-parse --verify <base>` failed. Recovery: `git fetch origin && git branch <base> origin/<base>`.
- **Local `<base>` has not advanced past the snapshot:** stop with "nothing new to review".
- **Snapshot branch is ahead of / diverged from local `<base>`:** show `git log --left-right` and ask.
- **Dirty tree at the merge step:** surface `git status`; ask the user to commit/stash. No auto-stash.
- **Merge conflict pulling the base in:** stop. Surface conflicted files. No auto-resolve.
- **Pre-commit hook fails on the fix commit:** surface output. No `--amend`, no `--no-verify`.
- **Promotion helper return 1 (worktree add):** stop. `<base>` is checked out somewhere, or a stale transient worktree lingers — surface the cleanup commands.
- **Transient-merge conflict (helper return 2):** stop. The branch (and its fixes) are safe on the local `$BRANCH`; resolve in the printed tmp path.
- **Re-anchor `--ff-only` refused (step 11):** surface it. Don't force; the local promotion already succeeded.

## What This Skill Will NOT Do

- Auto-stash or auto-discard uncommitted user work.
- Check out the base branch in the current worktree (the transient-worktree helper exists precisely to avoid this).
- Use `--amend`, `--no-verify`, `--no-gpg-sign`, or `git reset --hard` / `--force`.
- Bypass failing tests or hooks.
- Run destructive admin/DB commands without explicit approval.
- Skip the security pass — it runs every time, even when the diff is small.
- Commit fixes without showing the user the diff first.
- Promote to the base branch without explicit user confirmation.

## Quick Reference

| Phase | Command |
|-------|---------|
| Load config + helpers | `source .../_config.sh` then `source .../merge-helpers.sh` · `BASE` from `--base` (default `$WORKFLOW_BASE_BRANCH`) |
| Refuse if forbidden | check `$BRANCH ∉ {$BASE, master, main}` |
| Verify base exists locally | `git rev-parse --verify "$BASE"` |
| Range (LOCAL base, no fetch) | `git log HEAD..$BASE` · `git diff HEAD...$BASE` |
| Note unpublished gap | `git log --oneline origin/$BASE..$BASE` (cached ref, no fetch) |
| Read corpus — Tier 1 | `docs/best-practices.md` (+ any per-area best-practices doc the diff touches) |
| Read corpus — Tier 2 | root + nested `CLAUDE.md`, `docs/architecture.md`, `docs/product.md`, `docs/security.md`/`security/*`, `docs/api-conventions.md` |
| Best-practices alignment | A.1 — walk every Tier 1 scenario whose surface the diff touches |
| Architecture/doc-drift | C — flag arch changes shipped without `docs/architecture.md` reconciled |
| Deep-audit (conditional) | high-risk surface → invoke `nemesis-auditor` scoped to changed files |
| Plan | EnterPlanMode → list Design / Security / Doc-drift findings → ExitPlanMode |
| Advance snapshot | `git merge "$BASE"` |
| Apply fixes | per-project gates (same as `/base-test`) |
| Confirm + commit | `git status` + `diff`, await approval, conventional-commits HEREDOC |
| Promote to base (local) | ask user → `merge_into_branch_local "$BASE" "$BRANCH" "..."` (no push) |
| Re-anchor snapshot | `git merge --ff-only "$BASE"` |

## Naming note

The skill is called **`base-pr`** because the user invokes it to "review the pending PR on the base" — the new commits on `<base>` are treated as a pull request awaiting review. The **review branch** (`<base>-review`) is a **baseline snapshot**: it records where the base branch stood at the previous review. base-pr switches the worktree onto it (step 1), so the snapshot is always that dedicated branch — never the branch you happened to invoke from. Each `/base-pr` run reviews `snapshot..<base>` (local), then (after fixes are promoted) re-anchors the snapshot to the current local `<base>` — so the review branch is always "everything on the base that has already been reviewed." One review branch per base (`${BASE}-review`).

## Companion Skills

- **`base-push`** — uses the same `merge_into_branch_local` helper (now in [`.claude/scripts/merge-helpers.sh`](../../scripts/merge-helpers.sh)) for promotion; also the only skill that publishes the base to origin.
- **`base-merge`** — local-only sync of `<base>` ↔ a feature branch (no push).
- **`base-test`** — full gate sweep against a merged-in local `<base>`.
- **`nemesis-auditor`** — the adversarial deep-audit invoked by step 5D for high-risk diffs (wraps `feynman-auditor` + `state-inconsistency-auditor`).

---

**Skill Version**: 1.2.0
**Category**: Code Review / Git Workflow
_Version history: see [CHANGELOG.md](./CHANGELOG.md)._
