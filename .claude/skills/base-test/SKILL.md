---
name: base-test
description: Test ANY branch (default: the current one) against every project quality gate (lints, type-checks, builds, tests), optionally with the LOCAL base branch merged in first (default on). Operates in place — checks out the target in this worktree, no sandbox, no commit, no push. Pass `<target>` to test a branch/SHA/tag/`--pr <n>`; opt out of the base merge with `--as-is`. Gate commands are project-specific TODO sections to fill in. Base branch is configurable via `.claude/workflow.config` (default `main`).
---

# base-test — test any branch, run all gates

Test a **target** — by default the current worktree's branch, or any branch / SHA / tag / GitHub PR you name — against every project quality gate, and report the results. Reports failures together; does not auto-fix unless the user asks.

By default (`--with-base`, on unless you opt out) the skill first merges **local** `$WORKFLOW_BASE_BRANCH` into the target before running gates, answering "will this be green once it lands on base." Pass `--as-is` (or "skip the sync" / "test as-is") to test the target exactly, with no base merge.

This skill operates **in place** on whatever worktree it was invoked from. It does not create or use a sandbox worktree, and it does not commit, push, or promote anything. To test a different `<target>` it **checks that target out in the current worktree** (testing therefore **mutates** the worktree — unlike review, which is read-only). The only other write it performs is the optional local base merge — after that, everything is read-only test execution.

This is symmetric with `base-pr`, which reviews any branch / range / PR: `base-test` **tests** any branch / range / PR.

This is the "does this branch pass the gates — by itself, or with the latest local base merged in?" workflow.

> **Why local base, not `origin/<base>`?** A common workflow is to assemble work on local `<base>` and validate the whole batch *before* pushing. Sourcing the merge from `origin/<base>` makes unpushed local commits invisible to the test sweep — they slip past every gate and only get caught after they're already published. Operating on the local ref means any commit on `<base>` is in scope the moment it exists, pushed or not. The user is responsible for keeping local `<base>` synced with origin when they want to.

## When to Use

Invoked when the user says things like:

- "run base-test" / "test my branch" — no target named → test the **current** branch (default), with local base merged in unless opted out.
- "test branch `<name>`" / "test `<branch>`" / "run the gates against `<branch>`" — a named target → check it out in this worktree, then test.
- "test PR #N" / "run the gates on PR #N" — `--pr <n>` → fetch the PR head, check it out detached, then test.
- "test base" / "validate base" / "verify base is green" — the user names the configured base branch itself. **Special case — see below: the literal base is NEVER checked out** (it would block every other agent's worktree). It falls back to the default model: stay on the current feature branch and merge local base into it.
- "test as-is" / "skip the sync" / "don't pull base in" / "no merge" — `--as-is`: test the target exactly, no base merge.

## Invocation

```
base-test                          # test the CURRENT branch, with local <base> merged in (default)
base-test <branch>                 # check out a local branch in this worktree, then test (with base merged in)
base-test <sha-or-tag>             # detached checkout of a SHA/tag, then test
base-test --pr <n>                 # fetch + detached checkout of PR #n's head, then test
base-test --as-is                  # test the target EXACTLY — no base merge
base-test <target> --as-is         # the two compose
```

## Flags

| Flag / arg     | Default            | Effect |
| -------------- | ------------------ | ------ |
| `<target>`     | the current branch | What to test. A **local branch name** → checked out in this worktree. A **SHA / tag** → detached checkout. **Omitted** → the current branch (no checkout). See `--pr` for GitHub PRs. **Never** the literal base branch — that's the special case below. |
| `--pr <n>`     | off                | Target a GitHub PR: `git fetch` the PR head and check it out **detached**, then test. (`gh pr checkout` is one way to resolve the head; the checkout itself is plain git.) |
| `--with-base`  | **ON**             | Before running gates, merge local `<base>` into the target (the step-3 flow). The default — "usually if something hits base it's already tested," so this answers "will this be green once it lands on base." |
| `--as-is`      | off                | Test the target **exactly** — no base merge. The sync-opt-out phrases ("skip the sync", "test as-is", "don't pull base in", "no merge", "use the current branch as-is") are aliases for this. |

`--with-base` and `--as-is` are mutually exclusive (`--as-is` wins if both are somehow given). `<target>` composes with either.

### Special case: `<target>` resolves to the literal base branch

**NEVER check out the literal `$WORKFLOW_BASE_BRANCH` in this worktree.** A worktree sitting on `<base>` makes `git worktree add <base>` fail for *every other agent* in the fleet. So when the user asks to "test base" (the target resolves to the base branch itself):

- Do **not** check it out.
- Fall back to the **default model**: stay on the current (non-base) feature branch and merge local `<base>` into it — i.e. "test base" == "merge base into the current throwaway feature branch and test." This forces `--with-base` semantics on (`--as-is` against the literal base is meaningless — there'd be nothing distinct to test).
- If the current branch *is* `main` / `master` / `<base>`, the preflight already hard-stops — you can't be sitting on a protected branch. The user must be on a feature branch to "test base" this way.

## Preconditions

- **The current worktree is on a branch that is NOT `main`, `master`, or `$WORKFLOW_BASE_BRANCH`.** This skill checks out and runs against the resolved target; running it *from* a protected branch is a hard stop (the checkout, the optional merge, and the literal-base fallback all need a feature branch underneath).
- **The current worktree's working tree is clean** (no uncommitted changes). The skill checks out the target and (by default) performs a merge; uncommitted work blocks the checkout and would entangle with the merge. Hard stop if dirty.
- **The resolved `<target>` is NOT the literal base branch** as a thing to *check out* — the never-checkout-base special case redirects it to the merge-into-current fallback (see above). Any other branch / SHA / tag / PR head is fine to check out.
- **A local `$WORKFLOW_BASE_BRANCH` branch exists** (`git rev-parse --verify $WORKFLOW_BASE_BRANCH` succeeds) — required whenever `--with-base` is in effect (the default). The skill merges from LOCAL, not from `origin/<base>`, so unpushed commits on local are included. Recovery if missing: `git fetch origin && git branch <base> origin/<base>`. (With `--as-is` against a non-base target, a missing local `<base>` is not fatal — there's no merge.)
- Project-specific runtime prerequisites are available (e.g. a container runtime if your integration tests need one, language toolchains, etc.). List them in the **Project gates** section below.

## `--with-base` (default on) vs `--as-is`

The default contract is `--with-base`: **merge local `$WORKFLOW_BASE_BRANCH` into the target before running gates.** That's what makes the run a check against "will this be green once it lands on base" rather than "the target as it sits." Most invocations should take this default — *usually if something hits base it's already tested*, so the value of the sweep is in confirming the merged result. No fetch — local `<base>` is the source of truth (it's advanced by peers via `/base-push` / `/base-merge up`, all visible through the shared `.git`).

The caller may opt out (`--as-is`) when:

- They want to test the target exactly as-is, without pulling new base work into it.
- A bad commit just landed on local base and they explicitly want to test against an older baseline.
- They already merged local base into the target in this session and don't want a no-op merge cluttering the report.

**How to opt out:** pass `--as-is`, or the invoker says something like "skip the sync", "don't pull base", "test as-is", "no merge", or "use the current branch as-is" — all aliases for `--as-is`. When you see any of those signals (or anything semantically equivalent), **skip step 3's merge** entirely — don't fetch, don't merge — and note the opt-out in the final report.

If the signal is ambiguous (e.g., "just run the tests"), default to `--with-base` — that's the safer interpretation.

> **Note:** the literal-base special case (above) always runs `--with-base` semantics — `--as-is` against the base itself has nothing distinct to test.

## Execution Steps

### 0. Load workflow config

```bash
source "$(git rev-parse --show-toplevel)/.claude/scripts/_config.sh"
# $WORKFLOW_BASE_BRANCH and $WORKFLOW_MAIN_PATH are now set
# Sourcing merge-helpers.sh is REQUIRED — step 3 calls regen_merged_artifacts,
# which lives there. (It used to be inline in base-push/SKILL.md, which base-test
# never sourced, so the call was `command not found` mid-merge.)
source "$(git rev-parse --show-toplevel)/.claude/scripts/merge-helpers.sh"
```

### 1. Preflight — starting branch, clean tree, prerequisites

```bash
WT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "Not inside a git repository."; exit 1; }
cd "$WT_ROOT"

# This is the branch we START on — must be a feature branch (not protected),
# because the optional merge and the literal-base fallback both run on it.
CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
case "$CURRENT_BRANCH" in
  main|master|"$WORKFLOW_BASE_BRANCH")
    echo "Current branch is '$CURRENT_BRANCH' — base-test must run from a feature branch (not main/master/$WORKFLOW_BASE_BRANCH). Check out a feature branch and re-invoke."
    exit 1
    ;;
  HEAD)
    echo "Detached HEAD — check out a named feature branch and re-invoke."
    exit 1
    ;;
esac

# Clean working tree required — the skill checks out the target AND (by default)
# performs a merge; both need a clean tree.
if [ -n "$(git status --porcelain)" ]; then
  echo "Working tree is dirty. Commit or stash before running base-test (it checks out the target and merges local '$WORKFLOW_BASE_BRANCH' in)."
  exit 1
fi

# Local base branch must exist whenever --with-base is in effect (the default) —
# we merge from local, not from origin/<base>.
git rev-parse --verify "$WORKFLOW_BASE_BRANCH" >/dev/null 2>&1 || {
  echo "Local '$WORKFLOW_BASE_BRANCH' branch missing. Recovery: git fetch origin && git branch $WORKFLOW_BASE_BRANCH origin/$WORKFLOW_BASE_BRANCH"
  exit 1
}
```

> **Add project-specific preflight checks here.** Examples: container runtime (`docker info`), required CLIs (`command -v <tool>`), language toolchain present, ports free (`lsof -i :<port>`). Each failed check should print a clear recovery hint and `exit 1`.

Everything below runs with `cwd = $WT_ROOT`.

### 2. Check out the target (skip if testing the current branch)

Resolve `<target>` and land the worktree on it. **Testing mutates the worktree** — after the run it stays on the target. That's fine for a dedicated test agent (unlike review, which is read-only).

- **No `<target>` given** → nothing to check out; test the current branch. Skip this step. `TARGET_DESC="current branch $CURRENT_BRANCH"`.
- **`<target>` is the literal base branch** (`$WORKFLOW_BASE_BRANCH`) → **DO NOT check it out** (the never-checkout-base rule — a worktree on `<base>` breaks `git worktree add <base>` for every other agent). Stay on `$CURRENT_BRANCH`, force `--with-base` on, and skip the rest of this step — step 3's merge of local `<base>` into the current branch IS "test base." `TARGET_DESC="local <base> merged into $CURRENT_BRANCH (literal-base fallback)"`.
- **`<target>` is any other local branch** → `git checkout "<target>"`. `TARGET_DESC="branch <target>"`.
- **`<target>` is a SHA / tag** → `git checkout --detach "<target>"`. `TARGET_DESC="<target> (detached)"`.
- **`--pr <n>`** → fetch the PR head and check it out detached, e.g. `git fetch origin "pull/<n>/head" && git checkout --detach FETCH_HEAD` (or `gh pr checkout <n>` to resolve the head ref). `TARGET_DESC="PR #<n> (detached)"`.

After this step the worktree is on the target (or still on `$CURRENT_BRANCH` for the no-target / literal-base cases). Re-read the checked-out ref into a variable for the rest of the run.

> **Refuse to land the worktree on the literal base.** If resolving `<target>` would leave the worktree checked out on `$WORKFLOW_BASE_BRANCH` (e.g. someone passes the base name expecting a checkout), do not — apply the literal-base fallback above instead. The preflight already refuses *starting* on a protected branch; this refusal covers *landing* on the base via the target arg.

### 3. Merge local base into the target (`--with-base`, default; `--as-is` skips)

**Default behavior — runs every invocation unless the caller passed `--as-is` (see "`--with-base` vs `--as-is`" above).** This is the single most important step for the skill's default contract: gates run against the target **with the latest local `$WORKFLOW_BASE_BRANCH` merged in**, not against whatever it was sitting on before. Runs **after** the target is checked out (step 2), on whatever the worktree now points at.

`--no-commit` so the merge=ours generated artifacts are reconciled into the merge commit **before the gates run** — otherwise a drift-guard gate reds on the stale `merge=ours` index (`regen_merged_artifacts` is sourced from `.claude/scripts/merge-helpers.sh` in step 0):

```bash
TARGET_REF="$(git rev-parse --abbrev-ref HEAD)"   # the target's branch name, or "HEAD" if detached
PRE_MERGE_SHA="$(git rev-parse HEAD)"
if git merge --no-commit --no-ff "$WORKFLOW_BASE_BRANCH"; then
  if git rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then   # something merged
    if ! regen_merged_artifacts "$(git rev-parse --show-toplevel)"; then
      # Merge was CLEAN; artifact regen (docs/TODO.md + back-links) failed. This
      # is an IN-PLACE merge — no transient worktree — so reset and stop.
      echo "Artifact regen failed after a clean merge. Run 'git merge --abort'"
      echo "(resets to PRE_MERGE_SHA=$PRE_MERGE_SHA), fix the cause, and re-run base-test."
      exit 1
    fi
    git commit --no-edit -m "Merge branch '$WORKFLOW_BASE_BRANCH' into $TARGET_REF"
  fi
else
  echo "Merge conflict. Run 'git merge --abort' (resets to PRE_MERGE_SHA=$PRE_MERGE_SHA),"
  echo "or resolve, regenerate (node .claude/scripts/gen-todos.mjs), commit, then re-run."; exit 1
fi
CANDIDATE_SHA="$(git rev-parse HEAD)"
```

Notes:

- The merge source is **local `$WORKFLOW_BASE_BRANCH`** (`refs/heads/$WORKFLOW_BASE_BRANCH`), not `origin/<base>`. Unpushed commits on local are in scope.
- The merge runs on whatever the worktree points at after step 2's checkout — the named target branch, a detached SHA/tag/PR head, or (no-target / literal-base fallback) the original feature branch. On a detached HEAD the merge commit lands on the detached HEAD; that's fine — this skill never publishes it.
- **No fetch** — the local-first model never reads origin during a test run. Local `<base>` already reflects everything peers have advanced via `/base-push` / `/base-merge up` (shared `.git`).
- `--no-ff` keeps merge topology consistent.
- **`merge=ours` + regenerate** — `docs/TODO.md` is `merge=ours` (`.gitattributes`), so without the regenerate the merge keeps the target's stale `docs/TODO.md` and a drift-guard gate (`gen-todos.mjs` + `git diff --exit-code -- docs/TODO.md docs/todos`) would fail on the staleness after essentially every base merge that added a TODO. `regen_merged_artifacts` rebuilds the index on the merged tree so the gate sees a correct, clean index. (Driver registered per clone — `git config merge.ours.driver true`, via `.claude/scripts/setup-git-merge-drivers.sh`.)
- If the merge produces conflicts, **stop**, report the conflicted paths, and ask the user how to resolve (resolve → regenerate → commit). Do not auto-resolve.
- If the target is already up to date with local base, git will say "Already up to date" — proceed; `CANDIDATE_SHA` will equal `PRE_MERGE_SHA`.

**Note the local-vs-origin gap if any:** check `git log --oneline origin/$WORKFLOW_BASE_BRANCH..$WORKFLOW_BASE_BRANCH` (read-only against the cached origin ref — no fetch) — if non-empty, the merged local base includes unpushed commits. Surface this in the final report.

**If the caller passed `--as-is`:** skip the merge in this step entirely. Set `CANDIDATE_SHA="$(git rev-parse HEAD)"`, record `AS_IS=true` for the final report, and mention this prominently — "this run was NOT measured against the latest local base; the target was tested exactly".

The merge commit lives only on the local target ref (branch or detached HEAD). This skill never pushes it. If the user wants it published, that's a separate explicit action (e.g. `/base-push`).

### 4. Run every quality gate

Run gates in the order below. Stream output to the user so they see progress. **Do not stop on the first failure** — collect every failure across the full sweep, then report them together. Exception: if a gate's failure makes downstream gates meaningless (e.g., a dependency install fails and everything else can't even start), stop and surface that root cause first.

Run any dependency-install command at the worktree root once at the start of the sweep — out-of-date deps masquerade as type errors and break diagnosis.

> ### Project gates — configure this section
>
> The TODO blocks below are placeholders. Replace each with your project's actual gate command(s). Keep the structure (one block per logical gate) so failures are reported individually, not as one giant chunk of output.
>
> Common gate categories — keep, remove, or rename as your project needs:

#### 4a. Install dependencies

```bash
# TODO: project-specific dependency install
# Examples:
#   pnpm install --frozen-lockfile
#   npm ci
#   poetry install --no-root
#   bundle install --frozen
#   go mod download
```

#### 4b. Format check

```bash
# TODO: format/style check
# Examples:
#   pnpm format:check
#   prettier --check .
#   black --check .
#   gofmt -l . | grep . && exit 1
```

#### 4c. Lint

```bash
# TODO: lint
# Examples:
#   pnpm exec eslint .
#   ruff check .
#   golangci-lint run
```

#### 4d. Type-check

```bash
# TODO: type-check (if applicable)
# Examples:
#   pnpm exec tsc --noEmit
#   mypy .
```

#### 4e. Drift guards / codegen checks

```bash
# TODO: drift guards
# Pattern: re-run any codegen, then `git diff --exit-code -- <generated paths>`.
# Examples:
#   pnpm gen:types && git diff --exit-code -- types/generated/
#   make proto && git diff --exit-code -- proto/gen/
```

#### 4f. Unit tests

```bash
# TODO: unit tests
# Examples:
#   pnpm test:unit
#   pytest tests/unit
#   go test ./...
```

#### 4g. Build

```bash
# TODO: build
# Examples:
#   pnpm build
#   cargo build --release
#   go build ./...
```

#### 4h. Integration / E2E tests

```bash
# TODO: integration / E2E
# Often the most expensive gate. Spin up dependencies as needed.
# Examples:
#   pnpm test:e2e
#   pytest tests/integration
#   playwright test
```

### 5. Diagnose and report

This skill ends after the gate sweep. It does **not** auto-fix, commit, push, or promote.

**If every gate passed:** report a clean sweep (see step 6).

**If any gate failed:** for each failure, capture diagnostics so the user can act:

```bash
# What did the local base merge bring in? (skip if --as-is)
git log --oneline "$PRE_MERGE_SHA..$CANDIDATE_SHA"
git diff --stat "$PRE_MERGE_SHA..$CANDIDATE_SHA"
```

For each failure surface: the failing gate, the failing test name + the exact assertion, and a short log excerpt. If the merge brought in commits, point at the relevant chunk of `git diff $PRE_MERGE_SHA..$CANDIDATE_SHA`.

Then **ask the user** whether they want the failures fixed. If they say yes, apply fixes in place on the checked-out target, re-run the affected gate(s), and report — but still do **not** commit, push, or promote unless the user explicitly asks. The skill's contract stops at "run the tests and report"; anything beyond that is a separate, explicit request.

### 6. Report

Tell the user:

- The **target** the run executed against (`$TARGET_DESC` — current branch / named branch / detached SHA-tag / PR #n / literal-base fallback), the fact that the worktree is now left on that target, and that all preflight checks passed.
- **Whether the base merge ran (`--with-base`) or was skipped (`--as-is`).** If it ran: the commit range merged from local base (or "already up to date"), AND the count of unpushed commits on local base (from the local-vs-origin gap check in step 3) so the user sees whether the run included pre-publication work. If `--as-is`: state this prominently — "`--as-is` honored — this run was NOT measured against the latest local base; the target was tested exactly".
- For each gate: pass / fail. For failures, the diagnostics from step 5.
- That the local base merge commit (if any) is **local only** — it sits on the target ref (branch or detached HEAD) and has not been pushed. If the user wants it published, that's a separate action.
- If the run aborted mid-way (checkout failure, merge conflict, missing prerequisite, dirty tree, missing local base, protected branch), report exactly where, what state the worktree is in (including which ref it's on), and what the user needs to do to recover.

## What This Skill WILL Do

- Run **in place** in the current worktree, against the **target** (default: the current branch; or a named branch / SHA / tag / PR head it checks out — testing mutates the worktree, leaving it on the target).
- **Hard-stop** if the worktree *starts* on `main`, `master`, or `$WORKFLOW_BASE_BRANCH`, if the worktree is dirty, if local base doesn't exist (when `--with-base` is in effect), or if any project-specific preflight check fails.
- **NEVER check out the literal base branch** — if `<target>` is `<base>`, fall back to merging local `<base>` into the current feature branch and testing that.
- **By default (`--with-base`), merge local base into the target before running any gate** (no fetch — local `<base>` is the source of truth). This is on every invocation unless the caller passed `--as-is`.
- Honor `--as-is` (also "skip the sync", "don't pull base", "test as-is", etc.) by skipping the merge step entirely and flagging it in the report.
- Surface the local-vs-origin gap (unpushed commits on local base) so the user knows whether the run included pre-publication work.
- Run every project gate from section 4 and report pass/fail for each.
- Capture diagnostics on failure and ask the user whether to fix.

## What This Skill Will NOT Do

- Create or use a separate sandbox worktree — it runs where it was invoked (checking out the target in place).
- **Check out the literal base branch** (`$WORKFLOW_BASE_BRANCH`) in this worktree — that would break `git worktree add <base>` for every other agent. "Test base" falls back to merging local `<base>` into the current feature branch.
- Move the local base ref. (It's read for the merge, never advanced — promotion is `/base-push`.)
- Commit, push, or promote anything. The local base merge stays local; fixes (if the user opts into them) are not committed unless explicitly requested.
- Source the merge from `origin/<base>` — it always merges from local, so unpushed commits are part of the test sweep.
- Auto-FF local base to `origin/<base>` — the user owns local. If they want it forwarded, they do it themselves before invoking.
- Start on `main`, `master`, or `$WORKFLOW_BASE_BRANCH`. (Hard stop.)
- Run if the working tree is dirty. (Hard stop.)
- Run if local base doesn't exist while `--with-base` is in effect. (Hard stop — recovery hint in the error.)
- **Silently skip the base merge.** It's the default (`--with-base`); only skip it on an explicit `--as-is` signal, and always note it in the report.
- Use `--no-verify`, `--no-gpg-sign`, or any hook-bypass flag.
- Force-push anything.
- Attempt to resolve merge conflicts automatically.
- Skip in-scope gates because they're "probably fine."

## Quick Reference

| Phase                   | Command(s)                                                                                                                                       |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| Load config             | `source $(git rev-parse --show-toplevel)/.claude/scripts/_config.sh`                                                                             |
| Preflight               | *starting* branch ∉ {main, master, $WORKFLOW_BASE_BRANCH}; clean tree; `git rev-parse --verify $WORKFLOW_BASE_BRANCH` (when `--with-base`); project-specific prerequisites |
| Checkout target         | none → current branch · `<branch>` → `git checkout <branch>` · SHA/tag → `git checkout --detach <ref>` · `--pr <n>` → `git fetch origin pull/<n>/head && git checkout --detach FETCH_HEAD`. **Literal `$WORKFLOW_BASE_BRANCH` → never check out**; fall back to merge-into-current. Worktree left on target (mutating). |
| Base merge (`--with-base`, default; `--as-is` skips) | `git merge --no-commit --no-ff $WORKFLOW_BASE_BRANCH` into the checked-out target → `regen_merged_artifacts` → commit (no fetch) — every invocation unless caller passed `--as-is` |
| Note unpushed gap       | `git log --oneline origin/$WORKFLOW_BASE_BRANCH..$WORKFLOW_BASE_BRANCH` — surface count in the final report                                      |
| Run gates               | Section 4 — project-specific commands per gate                                                                                                  |
| Diagnostics on failure  | `git log --oneline "$PRE_MERGE_SHA..$CANDIDATE_SHA"`, `git diff --stat "$PRE_MERGE_SHA..$CANDIDATE_SHA"`, project-specific log paths              |

## Companion Skills

- **`base-merge`** — local-only sync of `<base>` ↔ the caller's branch (down/up). No tests.
- **`base-push`** — merge the caller's feature branch up into local `<base>` and publish to origin. No tests.
- **`base-pr`** — the review counterpart: reviews any branch / range / GitHub PR (default: pending changes on local `<base>`). `base-test` is the symmetric **test** counterpart — review any branch, test any branch.

## Difference vs. `base-push` / `base-merge` / `base-pr`

- **`base-merge`** syncs `<base>` ↔ the caller's branch locally (no network). No tests.
- **`base-push`** merges the caller's feature branch up into local `<base>` and publishes it to origin. No tests.
- **`base-pr`** *reviews* any branch / range / GitHub PR (default: pending changes on local `<base>`), applies fixes, promotes locally. Review is read-only on the worktree.
- **`base-test`** *tests* any **target** — by default the current branch, or any named branch / SHA / tag / `--pr <n>` it checks out in place (mutating the worktree) — running every project gate. By default (`--with-base`) it first merges **local** `<base>` into the target so the sweep answers "green once this lands on base"; `--as-is` tests the target exactly. Including unpushed local commits on `<base>` in the sweep is the whole point of sourcing the merge from local. It reports; it does not push or promote.

---

**Skill Version**: 1.2.0
**Category**: Quality / Test Gate
_Version history: see [CHANGELOG.md](./CHANGELOG.md)._
