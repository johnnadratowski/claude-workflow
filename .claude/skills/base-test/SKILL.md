---
name: base-test
description: Merge LOCAL base branch into the current worktree's branch, then run every project quality gate (lints, type-checks, builds, tests) against the merged result. Operates in place — no sandbox worktree, no commit, no push. Gate commands are project-specific TODO sections to fill in. Base branch is configurable via `.claude/workflow.config` (default `main`).
---

# base-test — merge LOCAL base into current branch, then run all gates

Merge **local** `$WORKFLOW_BASE_BRANCH` into the **current worktree's branch**, then run every project quality gate against the merged result. Reports failures together; does not auto-fix unless the user asks.

This skill operates **in place** on whatever worktree it was invoked from. It does not create or use a sandbox worktree, and it does not commit, push, or promote anything. It modifies the current branch only by performing the local base merge — after that, everything is read-only test execution.

This is the "if I merge the latest local base into my branch, does it still pass?" workflow.

> **Why local base, not `origin/<base>`?** A common workflow is to assemble work on local `<base>` and validate the whole batch *before* pushing. Sourcing the merge from `origin/<base>` makes unpushed local commits invisible to the test sweep — they slip past every gate and only get caught after they're already published. Operating on the local ref means any commit on `<base>` is in scope the moment it exists, pushed or not. The user is responsible for keeping local `<base>` synced with origin when they want to.

## When to Use

Invoked when the user says things like:

- "run base-test"
- "test base"
- "validate base"
- "run all the checks against base"
- "verify base is green"

## Preconditions

- **The current worktree is on a branch that is NOT `main`, `master`, or `$WORKFLOW_BASE_BRANCH`.** This skill merges into and runs against the checked-out branch; running it on a protected branch is a hard stop.
- **The current worktree's working tree is clean** (no uncommitted changes). The skill performs a merge; uncommitted work would be entangled with it. Hard stop if dirty.
- **A local `$WORKFLOW_BASE_BRANCH` branch exists** (`git rev-parse --verify $WORKFLOW_BASE_BRANCH` succeeds). The skill merges from LOCAL, not from `origin/<base>`, so unpushed commits on local are included. Recovery if missing: `git fetch origin && git branch <base> origin/<base>`.
- Project-specific runtime prerequisites are available (e.g. a container runtime if your integration tests need one, language toolchains, etc.). List them in the **Project gates** section below.

## Sync opt-out

The default contract: **always fetch `origin` (refresh) and merge local `$WORKFLOW_BASE_BRANCH` into the current branch before running gates.** That's what makes the run a check against "what's actually on local base right now, merged into my work" instead of "my branch as it sits." Most invocations should take this default.

The caller may opt out of the sync when:

- They want to test their branch exactly as-is, without pulling new base work into it.
- A bad commit just landed on local base and they explicitly want to test against an older baseline.
- They already merged local base into the current branch in this session and don't want a no-op merge cluttering the report.

**How to opt out:** the invoker says something like "skip the sync", "don't pull base", "test as-is", "no merge", or "use the current branch as-is". When you see any of those signals (or anything semantically equivalent), **skip step 2's merge** entirely — don't fetch, don't merge — and note the opt-out in the final report.

If the signal is ambiguous (e.g., "just run the tests"), default to syncing — that's the safer interpretation.

## Execution Steps

### 0. Load workflow config

```bash
source "$(git rev-parse --show-toplevel)/.claude/scripts/_config.sh"
# $WORKFLOW_BASE_BRANCH and $WORKFLOW_MAIN_PATH are now set
```

### 1. Preflight — branch, clean tree, prerequisites

```bash
WT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "Not inside a git repository."; exit 1; }
cd "$WT_ROOT"

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
case "$CURRENT_BRANCH" in
  main|master|"$WORKFLOW_BASE_BRANCH")
    echo "Current branch is '$CURRENT_BRANCH' — base-test must run on a feature branch (not main/master/$WORKFLOW_BASE_BRANCH). Check out a feature branch and re-invoke."
    exit 1
    ;;
  HEAD)
    echo "Detached HEAD — check out a named feature branch and re-invoke."
    exit 1
    ;;
esac

if [ -n "$(git status --porcelain)" ]; then
  echo "Working tree is dirty. Commit or stash before running base-test (it merges local '$WORKFLOW_BASE_BRANCH' into '$CURRENT_BRANCH')."
  exit 1
fi

git rev-parse --verify "$WORKFLOW_BASE_BRANCH" >/dev/null 2>&1 || {
  echo "Local '$WORKFLOW_BASE_BRANCH' branch missing. Recovery: git fetch origin && git branch $WORKFLOW_BASE_BRANCH origin/$WORKFLOW_BASE_BRANCH"
  exit 1
}
```

> **Add project-specific preflight checks here.** Examples: container runtime (`docker info`), required CLIs (`command -v <tool>`), language toolchain present, ports free (`lsof -i :<port>`). Each failed check should print a clear recovery hint and `exit 1`.

Everything below runs with `cwd = $WT_ROOT`.

### 2. Merge local base into the current branch (default; opt-out honored)

**Default behavior — runs every invocation unless the caller used a sync opt-out signal.** This is the single most important step for the skill's contract: gates run against the current branch **with the latest local `$WORKFLOW_BASE_BRANCH` merged in**, not against whatever the branch was sitting on before.

```bash
PRE_MERGE_SHA="$(git rev-parse HEAD)"
git fetch origin --quiet      # refresh origin/<base> for the local-vs-origin gap report below
git merge --no-ff "$WORKFLOW_BASE_BRANCH" -m "Merge branch '$WORKFLOW_BASE_BRANCH' into $CURRENT_BRANCH"
CANDIDATE_SHA="$(git rev-parse HEAD)"
```

Notes:

- The merge source is **local `$WORKFLOW_BASE_BRANCH`** (`refs/heads/$WORKFLOW_BASE_BRANCH`), not `origin/<base>`. Unpushed commits on local are in scope.
- The `git fetch` keeps `origin/<base>` fresh — used to detect the local-vs-origin gap, not as the merge source.
- `--no-ff` keeps merge topology consistent.
- If the merge produces conflicts, **stop**, report the conflicted paths, and ask the user how to resolve. Do not auto-resolve.
- If the current branch is already up to date with local base, git will say "Already up to date" — proceed; `CANDIDATE_SHA` will equal `PRE_MERGE_SHA`.

**Note the local-vs-origin gap if any:** after the merge, check `git log --oneline origin/$WORKFLOW_BASE_BRANCH..$WORKFLOW_BASE_BRANCH` — if non-empty, the merged local base includes unpushed commits. Surface this in the final report.

**If the caller opted out of the sync:** skip the fetch + merge in this step. Set `CANDIDATE_SHA="$(git rev-parse HEAD)"`, record `OPTED_OUT_OF_SYNC=true` for the final report, and mention this prominently — "this run was NOT measured against the latest local base".

The merge commit lives only on the local current branch. This skill never pushes it. If the user wants it published, that's a separate explicit action (e.g. `/base-push`).

### 3. Run every quality gate

Run gates in the order below. Stream output to the user so they see progress. **Do not stop on the first failure** — collect every failure across the full sweep, then report them together. Exception: if a gate's failure makes downstream gates meaningless (e.g., a dependency install fails and everything else can't even start), stop and surface that root cause first.

Run any dependency-install command at the worktree root once at the start of the sweep — out-of-date deps masquerade as type errors and break diagnosis.

> ### Project gates — configure this section
>
> The TODO blocks below are placeholders. Replace each with your project's actual gate command(s). Keep the structure (one block per logical gate) so failures are reported individually, not as one giant chunk of output.
>
> Common gate categories — keep, remove, or rename as your project needs:

#### 3a. Install dependencies

```bash
# TODO: project-specific dependency install
# Examples:
#   pnpm install --frozen-lockfile
#   npm ci
#   poetry install --no-root
#   bundle install --frozen
#   go mod download
```

#### 3b. Format check

```bash
# TODO: format/style check
# Examples:
#   pnpm format:check
#   prettier --check .
#   black --check .
#   gofmt -l . | grep . && exit 1
```

#### 3c. Lint

```bash
# TODO: lint
# Examples:
#   pnpm exec eslint .
#   ruff check .
#   golangci-lint run
```

#### 3d. Type-check

```bash
# TODO: type-check (if applicable)
# Examples:
#   pnpm exec tsc --noEmit
#   mypy .
```

#### 3e. Drift guards / codegen checks

```bash
# TODO: drift guards
# Pattern: re-run any codegen, then `git diff --exit-code -- <generated paths>`.
# Examples:
#   pnpm gen:types && git diff --exit-code -- types/generated/
#   make proto && git diff --exit-code -- proto/gen/
```

#### 3f. Unit tests

```bash
# TODO: unit tests
# Examples:
#   pnpm test:unit
#   pytest tests/unit
#   go test ./...
```

#### 3g. Build

```bash
# TODO: build
# Examples:
#   pnpm build
#   cargo build --release
#   go build ./...
```

#### 3h. Integration / E2E tests

```bash
# TODO: integration / E2E
# Often the most expensive gate. Spin up dependencies as needed.
# Examples:
#   pnpm test:e2e
#   pytest tests/integration
#   playwright test
```

### 4. Diagnose and report

This skill ends after the gate sweep. It does **not** auto-fix, commit, push, or promote.

**If every gate passed:** report a clean sweep (see step 5).

**If any gate failed:** for each failure, capture diagnostics so the user can act:

```bash
# What did the local base merge bring in? (skip if sync was opted out)
git log --oneline "$PRE_MERGE_SHA..$CANDIDATE_SHA"
git diff --stat "$PRE_MERGE_SHA..$CANDIDATE_SHA"
```

For each failure surface: the failing gate, the failing test name + the exact assertion, and a short log excerpt. If the merge brought in commits, point at the relevant chunk of `git diff $PRE_MERGE_SHA..$CANDIDATE_SHA`.

Then **ask the user** whether they want the failures fixed. If they say yes, apply fixes in place on the current branch, re-run the affected gate(s), and report — but still do **not** commit, push, or promote unless the user explicitly asks. The skill's contract stops at "run the tests and report"; anything beyond that is a separate, explicit request.

### 5. Report

Tell the user:

- The current branch the run executed against, and that all preflight checks passed.
- **Whether sync ran or was opted out.** If sync ran: the commit range merged from local base (or "already up to date"), AND the count of unpushed commits on local base (from the local-vs-origin gap check) so the user sees whether the run included pre-publication work. If opted out: state this prominently.
- For each gate: pass / fail. For failures, the diagnostics from step 4.
- That the local base merge commit is **local only** — it sits on the current branch and has not been pushed. If the user wants it published, that's a separate action.
- If the run aborted mid-way (merge conflict, missing prerequisite, dirty tree, missing local base, protected branch), report exactly where, what state the worktree is in, and what the user needs to do to recover.

## What This Skill WILL Do

- Run **in place** in the current worktree, against the currently checked-out branch.
- **Hard-stop** if the current branch is `main`, `master`, or `$WORKFLOW_BASE_BRANCH`, if the worktree is dirty, if local base doesn't exist, or if any project-specific preflight check fails.
- **By default, fetch origin (refresh) and merge local base into the current branch before running any gate.** This is on every invocation unless the caller used a sync opt-out signal.
- Honor a caller's sync opt-out by skipping the fetch+merge step entirely and flagging it in the report.
- Surface the local-vs-origin gap (unpushed commits on local base) so the user knows whether the run included pre-publication work.
- Run every project gate from section 3 and report pass/fail for each.
- Capture diagnostics on failure and ask the user whether to fix.

## What This Skill Will NOT Do

- Create or use a separate sandbox worktree — it runs where it was invoked.
- Touch any branch other than the current one. (The local base ref is read for the merge, never moved.)
- Commit, push, or promote anything. The local base merge stays local; fixes (if the user opts into them) are not committed unless explicitly requested.
- Source the merge from `origin/<base>` — it always merges from local, so unpushed commits are part of the test sweep.
- Auto-FF local base to `origin/<base>` — the user owns local. If they want it forwarded, they do it themselves before invoking.
- Run on `main`, `master`, or `$WORKFLOW_BASE_BRANCH`. (Hard stop.)
- Run if the working tree is dirty. (Hard stop.)
- Run if local base doesn't exist. (Hard stop — recovery hint in the error.)
- **Silently skip the sync from local base.** It's the default; only skip it on an explicit opt-out signal, and always note the opt-out in the report.
- Use `--no-verify`, `--no-gpg-sign`, or any hook-bypass flag.
- Force-push anything.
- Attempt to resolve merge conflicts automatically.
- Skip in-scope gates because they're "probably fine."

## Quick Reference

| Phase                   | Command(s)                                                                                                                                       |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| Load config             | `source $(git rev-parse --show-toplevel)/.claude/scripts/_config.sh`                                                                             |
| Preflight               | branch ∉ {main, master, $WORKFLOW_BASE_BRANCH}; clean tree; `git rev-parse --verify $WORKFLOW_BASE_BRANCH`; project-specific prerequisites       |
| Sync (default; opt-out) | `git fetch origin --quiet && git merge --no-ff $WORKFLOW_BASE_BRANCH` — every invocation unless caller said "skip sync" / "test as-is"           |
| Note unpushed gap       | `git log --oneline origin/$WORKFLOW_BASE_BRANCH..$WORKFLOW_BASE_BRANCH` — surface count in the final report                                      |
| Run gates               | Section 3 — project-specific commands per gate                                                                                                  |
| Diagnostics on failure  | `git log --oneline "$PRE_MERGE_SHA..$CANDIDATE_SHA"`, `git diff --stat "$PRE_MERGE_SHA..$CANDIDATE_SHA"`, project-specific log paths              |

## Companion Skills

- **`base-pull`** — merge `origin/<base>` into the caller's feature branch. No tests.
- **`base-push`** — merge the caller's feature branch up into the base and push. No tests.
- **`base-pr`** — review pending changes on the base in a sandbox, run gates there, promote on approval.

## Difference vs. `base-push` / `base-pull` / `base-pr`

- **`base-pull`** merges `origin/<base>` down into the caller's feature branch. No tests.
- **`base-push`** merges the caller's feature branch up into the base and pushes. No tests.
- **`base-pr`** reviews pending changes on the base (including unpushed commits) in a sandbox, applies fixes, promotes to origin.
- **`base-test`** merges **local** `<base>` into the current branch and then runs every project gate against the merged result. Including unpushed local commits on `<base>` in the test sweep is the whole point of sourcing from local. It reports; it does not push or promote.
