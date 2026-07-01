---
name: open-pr
description: Open a GitHub PR for finished work on a dedicated, frozen `pr/*` branch rooted at the repo's PR-target branch (e.g. master) — never the shared base branch itself. Scopes the diff from the TODO ledger's `commits:` (or snapshots a whole branch), gates it independently, auto-generates a reviewer guide + provenance body, tags the PR with its TODO id, and writes the `pr:` back-pointer. PR creation itself is user-gated. Use when the user says "open a PR", "put this up for review on GitHub", or /todo's close step offers it. ALSO updates an already-open PR in place — say "update pr 88", "update this pr", "revise pr 88", or "push changes to pr 88" and it checks out that PR's own head branch and works there (never rebuilds the change locally and orphans the PR).
---

# open-pr — dedicated, frozen PR branches

Open a GitHub PR whose head is a **dedicated, frozen `pr/<id>-<slug>` branch** — never the live shared base branch. The `pr/*` branch is cut from a **source branch** (default: the opening agent's current/feature branch; you can name any branch) and the PR **targets** a configurable branch (default `master`; `--into <branch>` to target the base branch `<base>` instead). Before review the `pr/*` branch is brought **up-to-date with its target** so it merges cleanly.

**Why a dedicated frozen branch:** a PR whose head is the live base branch mutates every time the fleet lands work — the diff accumulates unrelated changes, review guidance rots, and the PR can never be "done" (this happened: PR #52). A `pr/*` branch is **frozen** — it's a snapshot taken at open time; later base-branch work doesn't touch it.

Two ways to populate it:

- **From-source (default)** — `pr/*` is cut from `<source-branch>` (default the current branch) and synced up-to-date with the target. The PR is that branch's work, measured against the target. **The target controls the diff:** `--into <base>` (the base branch) gives a clean *feature-only* diff (your commits on top of the base); the default `master` target measures against master — broader, because a base-rooted source branch carries the base's *other* unmerged work too (see Guards).
- **`--scoped <ID…>`** — the surgical mode: cut from `origin/<target>` and bring over ONLY the named TODO(s)' `commits:` (cherry-pick, or path-split on a merge SHA). The PR diff is exactly that TODO's work measured against the target — parallel TODOs can have parallel clean PRs. (This was the prior default.)

And a third job — **updating** a PR that already exists (`--update <n>`): not a new branch at all, but working **on the open PR's head branch** and pushing there so it updates in place. See **[Update mode](#update-mode--revise-an-already-open-pr---update-n)**.

## When to Use

- **Create:** the user says "open a PR for <ID>", "put this up on GitHub", "publish this for review".
- **Update:** the user says "update pr 88", "update this pr", "revise pr 88", "push changes to pr 88" — a material change to an **already-open** PR → **[Update mode](#update-mode--revise-an-already-open-pr---update-n)**.
- `/todo done` / `/todo continue` reached its close step and the user answered yes to "open a PR for this work?".
- `/afk --pr-on-close` finished a clean run.

**Do NOT use** to publish the base branch to origin (that's `/base-push`), or to land work into the local base (that's `/base-merge up`). For servicing a **review round** on a PR (dispositioning reviewer comments), use `/pr-comments`; use Update mode for a substantive change to the PR's contents.

> **A coordinator instruction counts as the user** for invoking the skill — but the
> **create gate (step 5) is terminal-user-only**: PR creation publishes outward, so the
> title/body package is approved by the human (relayed through the coordinator is fine;
> implied is not).

## Invocation

```
/open-pr                           # from-source: cut pr/* from the current agent branch, target master
/open-pr <source-branch>           # cut pr/* from a named branch instead of the current one
/open-pr [<source>] --into <base>    # target the base branch (clean feature-only diff) instead of master
/open-pr --scoped <ID> [<ID2> …]   # surgical: cut from origin/<target> + cherry-pick the TODO(s)' commits:
/open-pr --update <n>              # UPDATE an already-open PR: check out its head branch + push there (alias: /open-pr update <n>)
Flags: --into <target> | --scoped | --update <n> | --draft | --reviewer <gh-user> | --label <l> … | --title <t> | --absorb <n>
```

## Execution Steps

### 0. Config + target/source resolution

```bash
source "$(git rev-parse --show-toplevel)/.claude/scripts/_config.sh"
source "$(git rev-parse --show-toplevel)/.claude/scripts/merge-helpers.sh"   # merge_into_branch_local (step 7 --absorb)

# PR TARGET (what the PR diffs against / merges into): --into <branch> wins,
# else the configured PR target, else the repo's default branch.
TARGET="${INTO:-${WORKFLOW_PR_TARGET_BRANCH:-$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')}}"
[ -n "$TARGET" ] || TARGET=$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name)

# SOURCE branch the pr/* is cut from (from-source mode): a positional
# <source-branch> if given, else the current agent branch. (--scoped ignores this
# and cuts from origin/$TARGET — see step 1.)
CALLER=$(git rev-parse --abbrev-ref HEAD)
SOURCE="${SOURCE_ARG:-$CALLER}"
# Is the target local-only (e.g. the base branch `<base>`) or a published remote
# (e.g. master)? Drives whether step 2 syncs from origin/<target> or the local ref.
if git rev-parse --verify "refs/remotes/origin/$TARGET" >/dev/null 2>&1; then
  TARGET_REF="origin/$TARGET"; TARGET_REMOTE=1
else
  TARGET_REF="refs/heads/$TARGET"; TARGET_REMOTE=0   # local base branch, never pushed
fi
```

### 1. Fetch, then cut the branch — HARD REFUSALS first

This workflow's base skills never fetch, so the cached `origin/<target>` may be stale. Fetch the target before using it — but only when it's a published remote branch (a local-only target like the base `<base>` has no origin ref to fetch; it's synced from the local ref in step 2):

```bash
[ "$TARGET_REMOTE" = 1 ] && git fetch origin "$TARGET"
```

**Refuse outright** (no override flag exists):

- A PR head of `<base>` or `<target>` — the PR #52 lesson, codified. The head is ALWAYS a fresh `pr/*` branch (so even when `<source>` is the base branch, you cut a fresh `pr/*` FROM it, never PR the live ref).
- A dirty working tree (commit or stash first — the skill switches branches).

Branch name: `pr/<id-or-source-slug>-<slug>` (from-source: derive from the TODO id if given, else `$SOURCE` + a short slug; `--scoped` multi-ID uses the first ID + a joint slug).

**Switch in place — do NOT use a transient worktree.** A `pr/*` branch is private and single-use, so it can be checked out in the caller's own worktree; the tree is already clean (the hard-refusal above), so the switch is safe. `$CALLER` was captured in step 0. Cut the branch:

```bash
# From-source (default): a frozen snapshot of the source branch tip.
git checkout -b "pr/<…>" "$SOURCE"
# --scoped: root at the target instead, then cherry-pick the ledger commits in step 2:
#   git checkout -b "pr/<…>" "$TARGET_REF"
```

**Return timing is freeze-critical** — steps 2–5 (sync/scope, gate, push, create) all run while sitting ON the `pr/*` branch; the return to `$CALLER` happens **after step 5's push + create and before step 6's `pr:` ledger commit** (step 6 performs it as its first action), so the back-pointer never lands on the frozen `pr/*` branch. On **any failure**, return immediately and clean the tree first so the checkout doesn't carry/block on partial state:
- from-source sync conflict (step 2 merge of the target into `pr/*`) → `git merge --abort`, then `git checkout "$CALLER"`.
- `--scoped` cherry-pick conflict → `git cherry-pick --abort`, then `git checkout "$CALLER"`.
- `--scoped` path-split fallback mid-flight (staged `git checkout <base> -- …` into the index) → `git checkout -f "$CALLER"` (or `git reset --hard` first) — you're abandoning the `pr/*` branch, so discarding its staged state is correct.

> **Why in-place, not a worktree?** The transient worktree in `merge_into_branch_local` is load-bearing only because the **base** branch (`<base>`) must never be checked out fleet-wide (it breaks `worktree add <base>` for every worktree sharing the `.git`). A private `pr/*` branch has no such constraint. In-place is simpler **and** keeps the caller's untracked files present — notably `server/.env` (and any other gitignored env) — so the **pre-push hook's env-dependent gates pass**; a fresh worktree lacks them and the hook fails at push. The worktree stays ONLY on the `--absorb` path (step 7), which merges into the base.

### 2. Bring up to date with the target (from-source) — or scope the content (`--scoped`)

**From-source (default):** the `pr/*` branch already holds the source branch's work (cut in step 1). Now bring it **up-to-date with the target** so it merges cleanly and the diff measures only against the current target tip:

```bash
git merge --no-ff "$TARGET_REF"   # origin/master for the default target; refs/heads/<base> for --into <base>
```

Resolve any conflicts (or `git merge --abort` + return per step 1's cleanup). Merging the target in advances the merge-base to the target's tip, so the eventual PR diff is **exactly the source branch's commits not already in the target** — no cherry-pick, no ledger dependency (the source branch IS the scope). For `--into <base>` that's your feature commits on top of the base; for the default `master` target it's everything on the source not yet in master (see Guards re: breadth).

**`--scoped` mode:** the `pr/*` branch was cut from `$TARGET_REF` (step 1); bring over ONLY the named TODO(s)' work. Read each named TODO's `commits:` frontmatter (active or `completed/`). That list is the scope.

> **Ledger-timing precondition.** Under the **close-before-publish** rule (`/todo` step 9) the TODO is normally **already closed** when `/open-pr` runs (`commits:` populated, file in `completed/`). For the **from-source default** (whole-branch diff) the close commit — the archive `mv` + regenerated `docs/TODO.md` — rides inside the PR automatically. For **`--scoped`** it does NOT: `done` writes `commits:` *before* it archives, so the close commit isn't in `commits:`, and cherry-picking only `commits:` omits it — the scoped `pr/*` would drop `completed/<ID>.md` (and could even ship `<ID>` as still-active, re-introducing the lag this rule fixes). **So `--scoped` MUST also bring the ledger files** — `git checkout <source> -- docs/todos/completed/<ID>.md docs/todo_plans/completed/<slug>.md` — before the step-3 `gen:todos` regen. If instead you're opening a PR for **in-progress** work, `commits:` may be empty: pass them explicitly via `--commits <sha…>`, or derive them with `git log --reverse --format=%H --grep "<ID>" "origin/$TARGET..HEAD"`. **Do not** fall back to a raw branch-range (`origin/$TARGET..HEAD`): a long-lived feature/base branch carries unrelated history (the whole `<base>` lineage), so the range is not the scope — the ledger (or `--commits`) is.

- **Plain commits** → `git cherry-pick` onto the `pr/*` branch, oldest-first across all named IDs.
- **A merge SHA anywhere in scope is an explicit fallback trigger** — do NOT attempt `-m`/`-m 1` cherry-picks. Fall back to the **path-based split**: `git checkout <base> -- <paths>` for the TODO's files, with **dependency-closure discipline** — if a brought-over file imports something only present on `<base>`, the dependency's files join the set (whole files, never hybrid states), and the gates in step 3 prove closure. Same procedure as the PR #52 split.
- Cherry-pick conflicts that resolve trivially (context drift) are fine; entangled conflicts → switch to the path-based fallback rather than hand-weaving patches.

**Twin-content commits are expected, not a problem**: the `pr/*` branch re-creates content that also exists on `<base>`. Under the `<base> ⊇ <target>` invariant (the target only advances from base-derived content, and the base absorbs the target right after — step 7), the eventual merge-back is a clean no-op.

### 3. Regenerate artifacts, then gate independently

**First, regenerate generated artifacts on the `pr/*` branch and commit** — `pnpm gen:todos`, swagger, sql-types, and any other codegen the scoped change touches. A generated file produced against the *source* branch's state (the cherry-pick carries it verbatim) can drift on the master-rooted branch and trip the drift guard; regenerating reconciles it to the target's state + the scoped change. (In the DX-8013 dogfood this only stayed hidden because the source and target todo sets happened to be identical.)

Then run the project's CI-mirror gates **on the `pr/*` branch**. A scoped branch must be green **standing on the target alone** — this is what catches hidden dependencies on unreviewed base-branch content (it caught five real ones in the PR #52 split). Failures mean the dependency closure is incomplete (go back to step 2) or the work genuinely depends on another TODO — say so and ask whether to widen scope or block.

> **Distinguish your failures from pre-existing target defects.** A gate that reds on the `pr/*` branch **and also reds on the pristine `origin/<target>`** is a pre-existing defect, not this PR's to fix — record it in the provenance block and move on; do NOT block the PR or edit unrelated files to chase it. Only a failure *introduced by the scoped change* blocks. (Dogfood: `format:check` failed on `.claude/settings.local.json` — tracked-and-broken on master, not in the diff.) Note also that the push in step 5 re-runs the local pre-push hook (the full TS gate sweep); for a docs-only change that's heavier than the change warrants but is unavoidable through the hook — the in-place switch (step 1) is what keeps the env files present so it passes.

### 4. Compose the PR package

Auto-generate, then show the user (step 5):

- **Title**: conventional-commit style, referencing the ID.
- **Body**:
  - **TODO tag block** — `TODO: <ID>` + link to `docs/todos/<ID>.md` (or `completed/<ID>.md`), plan link. This block is the single tagging implementation other skills call back into (see Tagging below).
  - **Review guide derived from the plan** — focus files (the meat) vs skip list (generated artifacts, machinery), in the reviewer's terms.
  - **Provenance** — `plan_review:` record, diff-review GREEN (which agent, date), gates evidence (what ran, result). This block doubles as the agent-prepared provenance (the body is agent-drafted, user-approved at create).
  - **Merge guidance** — merge-commit only (never squash/rebase a branch whose commits are twins of base-branch commits; squash re-writes them and breaks the absorb).

Any *comment* `/open-pr` later posts on the PR (not the body) carries the same two author signals `/pr-comments` uses: it **starts with** the visible tag from `.claude/scripts/agent-identity.sh tag` (`**[AGENT RESPONSE · <name> / <role>]**`, or `**[AGENT RESPONSE]**` when identity is unresolvable) for human transparency, and **ends with** the invisible `<!-- agent-authored:pr-comments -->` marker so a future review round can classify thread authorship consistently. (The PR **body** is exempt — it's agent-drafted but user-approved at create.)
- **Labels**: `todo:<ID>`, plus labels derived from the TODO's `area`/`tags`, plus `--label` extras. Snapshot mode: label `batch`. **`gh pr create --label` errors on a label that doesn't exist in the repo** — before create, `gh label list` and `gh label create` the missing ones (or filter to existing). Labels are best-effort convenience; the body's **TODO tag block is the canonical linkage**, so never block create on a label gap.
- **Reviewers** from `--reviewer`.

### 5. Create — USER-GATED

Creating the PR **is an outward-facing post**: title, body (including internal provenance), labels, and reviewer requests all publish on create. **Show the user the complete package and get explicit approval BEFORE running:**

```bash
git push -u origin "pr/<…>"
PR_URL=$(gh pr create --base "$TARGET" --head "pr/<…>" --title … --body-file … [--draft] [--reviewer …] [--label …])
echo "$PR_URL"
```

Same terminal-reviewer principle as `/pr-comments`' atomic posting — no auto-create, ever. `--draft` still gates (a draft is visible to the repo).

**Always surface the PR URL.** `gh pr create` prints the new PR's URL on success — capture it (`PR_URL=$(gh pr create …)`) and echo it as the **final confirmation line** to the user. The link is the deliverable; it must never be buried in step output. (Same on `--absorb`/merge bookkeeping — when you reference the PR, include its URL.)

**Then post the commit-manifest comment** ([Commit-manifest comment](#commit-manifest-comment) below) — the full-PR range (`RANGE="$TARGET_REF..HEAD"`, `--no-merges`), a per-commit walkthrough with a diff link for each, so a reviewer can read the PR commit-by-commit. **MANDATORY on every create** (Update mode posts a per-round delta at U5) — never skip it.

### 6. Tagging + the `pr:` back-pointer

**This skill owns TODO↔PR tagging** — one implementation, reused everywhere (`/pr-comments` calls back into this step when TODO state changes so the PR's tag block stays true):

- **First, return to the caller's branch**: `git checkout "$CALLER"` (the tree is clean — step 3 committed the regen and gates are read-only; assert if unsure). This is the freeze-critical return from step 1's timing note — do it here, before the commit below, so the `pr:` bump can't land on the frozen `pr/*` branch.
- Write `pr: <n>` into each in-scope TODO's frontmatter (active or completed), bump `updated`, run `pnpm gen:todos` (the generator validates the field), commit. **This commit lands on the source/base side** — the branch that owns the TODO ledger (e.g. `<base>` / the caller's branch you just returned to). **Never** commit it onto the frozen `pr/*` branch (that would un-freeze the reviewed content). On PR **merge**, append the target-branch merge SHA to the TODO's `commits:` so the ledger records where it shipped. `pr:` is single-valued — a second PR for the same TODO (e.g. a reopen shipped separately) overwrites it to the **latest**; earlier PRs stay discoverable via `commits:` and the PR-side `todo:<ID>` label.
- **Snapshot/batch PRs**: the body lists every TODO whose `commits:` fall inside `<target>..<SHA>`; each of those TODOs gets `pr: <n>`. Same field, many writers — "which PR shipped this" stays answerable in both modes.
- **No good TODO id?** Tagging is optional — but the PR is then **clearly marked agent-created-without-TODO**: label `agent-no-todo` + a body banner line. If the work plausibly warrants a TODO, RECOMMEND minting one to the user before creating.

### 7. Post-merge absorb — `--absorb <n>`

Offered automatically when `gh pr view <n>` shows the PR merged (and runnable later as `/open-pr --absorb <n>`):

```bash
git fetch origin "$TARGET"
merge_into_branch_local "$WORKFLOW_BASE_BRANCH" "origin/$TARGET" \
  "Merge origin/$TARGET into $WORKFLOW_BASE_BRANCH (absorb PR #<n>)"
absorb_rc=$?
```

(`merge_into_branch_local` is the canonical transient-worktree helper sourced from `.claude/scripts/merge-helpers.sh` in step 0.) This restores `<base> ⊇ <target>` immediately so future twin-content merges stay no-ops. **It never pushes `origin/<base>`** — publishing the base remains `/base-push`'s human-gated job.

> **Route the return code BEFORE the cleanup below — this is freeze-critical.** Only on `absorb_rc == 0` (the absorb actually landed) do you proceed to the ledger update + `pr/*` deletion. On any non-zero, **STOP**: the absorb did NOT complete, `<base> ⊇ <target>` is NOT restored, and a transient worktree may be preserved.
> - **1** — worktree-add failure (base checked out somewhere, or a stale transient worktree). Surface the cleanup commands; nothing landed.
> - **2** — merge conflict; transient worktree preserved at the printed path. The user resolves there.
> - **3** — post-merge regen/commit failure; transient worktree preserved at the printed path. The user finishes the commit there.
> In every non-zero case: do **NOT** write the merge bookkeeping and do **NOT** delete the `pr/*` branch — deleting the reviewed, merged-on-GitHub branch while the local absorb never completed would destroy the only frozen copy. Report the state and let the user finish the absorb, then re-run.

**Only when `absorb_rc == 0`:** update the TODO ledger (step 6's merge bookkeeping) and delete the remote `pr/*` branch (a repo with delete-branch-on-merge enabled — a repo setting, not configured by this skill — already did; otherwise `git push origin --delete pr/<…>` — ask first, it's a remote deletion).

> **`--into <base>` PRs don't take this absorb path.** The block above absorbs a merged **master**-target PR back into local `<base>` to restore `<base> ⊇ master`. A PR that targeted the base branch itself instead **advanced `origin/<base>` on merge** — so there's no master to absorb; instead reconcile local `<base>` with the now-advanced remote: `git fetch origin "$WORKFLOW_BASE_BRANCH"` then fast-forward/merge `origin/<base>` into local `<base>` (and tell the user, since `origin/<base>` moving is normally `/base-push`'s job).

## Update mode — revise an already-open PR (`--update <n>`)

Use this when the user says **"update pr 88" / "update this pr" / "revise pr 88" / "push changes to pr 88"** — a material change to a PR that **already exists**. Unlike create, it does **not** cut a new branch: it works **on the PR's existing head branch** and pushes there, so the PR updates in place.

> **Never rebuild a PR locally — the reason this mode exists (PR #86).** The change was built on a local/base/feature branch, the PR head was never pushed, so the PR went stale and had to be closed. To change an open PR you **checkout → commit → push its head** — always.

### U0. Preamble — run FIRST (Update mode does NOT inherit create's step 0)

Establish Update mode's own context before touching any branch — the create-path step 0 never runs on a `--update` invocation:

```bash
source "$(git rev-parse --show-toplevel)/.claude/scripts/_config.sh"
source "$(git rev-parse --show-toplevel)/.claude/scripts/merge-helpers.sh"
RETURN_BRANCH=$(git rev-parse --abbrev-ref HEAD)   # where the user is now; return here in U7
```

`RETURN_BRANCH` — **not** create's `$CALLER` — is Update mode's return target, and it is NOT automatically the ledger branch (see U6: it can BE the PR head).

**Resolve the PR number.** `--update <n>` (or `update <n>`) names it. If omitted ("update this pr"), resolve in order — never guess silently:

1. the current branch **is** an open PR head — `gh pr list --head "$(git branch --show-current)" --state open --json number -q '.[0].number'`,
2. else the in-scope TODO's `pr:` frontmatter,
3. else **ask** which PR.

### U1. Acquire the PR's head branch — MANDATORY FIRST (the anti-footgun)

```bash
gh pr view <n> --json state,headRefName,baseRefName,isCrossRepository,url
```

**Hard refusals:**

- `state != OPEN` → a merged/closed PR can't be updated; that's a **new** PR (use create mode). Stop with that hint.
- `isCrossRepository == true` → the head lives on a fork you can't push to. Stop.
- A dirty working tree → commit/stash first (the skill switches branches).

Then get **onto the PR's code** — the whole point of the mode:

```bash
git fetch origin "<headRefName>"
```

**Guard local unpushed work before checkout.** The U1 dirty-tree refusal catches only *uncommitted* changes — `git checkout -B … origin/<head>` would still hard-reset a local `<headRefName>` that has *committed-but-unpushed* work (possibly the very update to ship) to origin, orphaning it to the reflog. So only `-B`-reset when the local branch is absent or not ahead of origin:

```bash
if git show-ref --verify --quiet "refs/heads/<headRefName>" \
   && [ -n "$(git rev-list origin/<headRefName>..<headRefName> 2>/dev/null)" ]; then
  git checkout "<headRefName>"                              # local is ahead of origin — keep it, do NOT reset
else
  git checkout -B "<headRefName>" "origin/<headRefName>"    # fresh/behind — track the PR head
fi
```

**Warn (don't refuse)** if `<headRefName>` doesn't match `pr/*` — a PR opened off a live/base branch is the PR #52 anti-pattern; proceed on whatever the head is, but flag it and recommend a frozen `pr/*` next time. `$RETURN_BRANCH` (captured in U0) is where you return in U7.

### U2. Merge the PR's base in FIRST — before implementing

Merge the branch the PR is **based on** into the head **before** you make the change, so you build on the PR's current base instead of hitting a hard merge after diverging. This matters most for a **stacked PR**: `baseRefName` is then the **parent PR's head branch**, which may have changed materially since this PR was cut — the concrete PR-based-on-a-PR pain.

```bash
git fetch origin "<baseRefName>"
git merge --no-ff "origin/<baseRefName>"   # baseRefName = the PR's declared base: master/<base>, or a parent PR's branch when stacked
```

**merge, not rebase** — the head is published. Resolve conflicts here: *before* implementing they're smaller and cleanly the base's, not entangled with your new work (merging *after* implementing is the hard merge this ordering exists to avoid). A conflict → surface it. If the base advances again during a long implement, re-merge before the U5 push (a stale push is rejected non-ff anyway).

### U3. Make the change — via the normal workflow, on this branch

The requested change runs through the standard `/todo` procedure — plan → plan-review → peer plan-review → implement → **doc-sync (C-12)** → review → peer review → test — scaled to the change's size. **Every commit lands on the checked-out head.** If the change already exists as commits elsewhere, bring them over with `git cherry-pick` (or the create step-2 path-split fallback for a merge SHA) — **never rebase** a published branch.

### U4. Regenerate artifacts + gate independently

Same as create **step 3**: regenerate any codegen the change touched (`pnpm gen:todos`, swagger, sql-types), commit, then run the CI-mirror gates **on the head**. Distinguish a failure your change introduced (blocks) from a pre-existing target defect (record + move on).

### U5. Push the head — USER-GATED

Pushing publishes outward, so it's user-gated exactly like create's step 5. **Capture the pre-push head first** (the delta baseline for the manifest), show the user the new commits + the resulting PR diff, get approval, then push:

```bash
PREV=$(git rev-parse "origin/<headRefName>")   # delta baseline — BEFORE the push
git push origin "<headRefName>"
```

If the user **declines** the push, stop here: the head carries U2–U3's committed-but-unpushed work (the base merge + your implement commits), diverging from `origin/<headRefName>`. Nothing is lost — leave it for a later push (re-run U5 when ready), do **not** post the manifest (the PR content hasn't changed yet), and tell the user the PR is **not** updated.

Then **post a commit-manifest comment scoped to this update** ([below](#commit-manifest-comment)) — `RANGE="$PREV..HEAD"`, header "Commits in this update" — re-request review, and surface the PR URL as the final line:

```bash
gh pr edit <n> --add-reviewer <user>    # or: gh api …/requested_reviewers
gh pr view <n> --json url -q .url
```

### U6. Ledger — on the TODO-owning branch, NEVER the head

Append the new commits to the TODO's `commits:` (the `pr:` back-pointer is already set — this PR exists — so it's just commit bookkeeping). **The ledger commit must land on the TODO-owning branch, which is NOT blindly `$RETURN_BRANCH`:** if the user invoked Update mode from the PR head itself (resolution rule #1), `$RETURN_BRANCH == headRefName`, and committing the ledger there would un-freeze the reviewed head (step 6's "Never") and diverge from origin. Resolve it explicitly with a head guard:

```bash
LEDGER_BRANCH="$RETURN_BRANCH"
[ "$LEDGER_BRANCH" = "<headRefName>" ] && LEDGER_BRANCH="$WORKFLOW_BASE_BRANCH"   # invoked-from-head → the base owns the ledger
```

Commit the bump on `$LEDGER_BRANCH`, **never** on `<headRefName>`. If `$LEDGER_BRANCH` is the local base (which the fleet rule forbids checking out in-place), make the edit through a transient worktree — `git worktree add` the base (the same no-in-place-checkout discipline `merge_into_branch_local` uses), edit the TODO + `pnpm gen:todos`, commit, `git worktree remove` — rather than `git checkout`-ing the base.

### U7. Return

`git checkout "$RETURN_BRANCH"`.

## Commit-manifest comment

**MANDATORY on every create (step 5) AND every Update-mode push (U5)** — not optional. It's a per-commit walkthrough so a reviewer can read the change **one commit at a time**, each linking to that commit's diff. This is useful precisely because **commits are phase-atomic** — one coherent, separately-reviewed phase per commit (see [`feature.md`](../../agent-roles/feature.md) → phased implementation). The manifest surfaces that structure; it is not a substitute for reading the diff.

Build the list with **`git log --no-merges`** over the range for the mode — `--no-merges` **excludes merge commits**, which are not review units (a base/target-sync merge like U2's carries no standalone chunk to review; posting it as a "commit" is the noise we avoid):

- **Create (step 5)** → all the PR's real commits: `RANGE="<target-ref>..HEAD"` (e.g. `origin/master..HEAD`); header **"Commits in this PR"**.
- **Update (U5)** → **only this round's new commits**: capture the pre-push head first (`PREV=$(git rev-parse origin/<headRefName>)` **before** U5's push), then `RANGE="$PREV..HEAD"`; header **"Commits in this update"**. Each update posts a **fresh comment** scoped to that round — a running per-round trail the reviewer follows.

```bash
N=<pr-number>; RANGE="<per the mode above>"; HEADER="Commits in this update"   # or "Commits in this PR" on create
read -r OWNER REPO < <(gh repo view --json owner,name -q '.owner.login + " " + .name')
BASE="https://github.com/$OWNER/$REPO/pull/$N/commits"
{
  .claude/scripts/agent-identity.sh tag                 # visible **[AGENT RESPONSE · <name> / <role>]** head
  echo; echo "### $HEADER"; echo
  git log --no-merges --reverse --format="- [\`%h\`]($BASE/%H) — %s" "$RANGE" \
    | grep . || echo "_(no non-merge commits in this range)_"
  echo; echo "<!-- agent-authored:pr-comments -->"      # invisible authorship marker
} > "/tmp/pr-$N-manifest.md"
gh pr comment "$N" --body-file "/tmp/pr-$N-manifest.md"
```

- **Diff link per commit** — `…/pull/<n>/commits/<full-oid>` opens that commit's changes **in PR context** (the PR's commit view), not the bare repo commit page.
- **Merge commits are excluded** by `--no-merges`. If a merge ever carried conflict-resolution changes worth review, call that out in prose — don't rely on the manifest to surface it.
- **One line per commit** — `%s` (subject) is the description; keep it scannable (don't paste commit bodies).
- **Empty range** — an update that only re-synced the target (no new work) yields no lines; the `grep . ||` fallback says so rather than posting an empty list.
- **Author signals** — starts with the `agent-identity.sh tag` (human transparency), ends with the `<!-- agent-authored:pr-comments -->` marker (so a later `/pr-comments` round classifies authorship), like every comment this skill posts (step 4).

## Guards (warn, don't refuse)

- **From-source diff breadth (default mode).** A feature branch is usually `<base>`-rooted, so a `pr/*` cut from it and targeted at **master** diffs as "everything on the branch not in master" — which pulls in the base's *other* unmerged fleet work, not just yours (the PR #52 accumulation pattern). If you want a clean *feature-only* diff, target the base with **`--into <base>`** (diff = your commits on top of the base) or use **`--scoped <ID>`** for a surgical master-targeted PR. Warn when from-source + master target is chosen on a `<base>`-rooted source so the user picks deliberately.
- **A `--into <base>` PR advances `origin/<base>` when merged — heads-up, not a neutral default.** Targeting the base branch means the GitHub merge writes `origin/<base>`, which is otherwise advanced only by the human-gated `/base-push`. Prefer the local `/base-push` flow to land into the base (or target `master`); if you do use `--into <base>`, confirm with the user first. (If a long-lived PR ever re-freezes `origin/<base>` at a specific SHA — the PR #52 situation — escalate this back to an active discouragement until that PR merges.)
- An in-scope TODO has no review record (`plan_review:` missing/skipped on a complex plan, or no diff-review GREEN evidence) → warn; the user may still proceed (the PR's provenance section then says so honestly).
- `<base> ⊉ <target>` (`git merge-base --is-ancestor origin/$TARGET <base>` fails) → warn: someone landed to the target without an absorb; recommend running `--absorb` first so twin detection stays clean. (Applies to the master-target case; a `--into <base>` PR has no absorb dance — see step 7.)
- **Target advanced while a PR is open** → merge the target ref into the `pr/*` branch (**merge, not rebase** — it's published) and re-run the gates before re-requesting review.

## What This Skill Will NOT Do

- Use `<base>` or `<target>` as a PR head — refused, no override.
- Run `gh pr create` (or push the `pr/*` branch) before the user approves the package.
- Push `origin/<base>` — only `/base-push` does that, and only human-gated.
- Spin up a transient worktree for the `pr/*` branch — switch in place (step 1); the worktree is only for the `--absorb` base merge.
- Block the PR on a gate that also reds on the pristine `origin/<target>` (pre-existing defect) or on a missing label (best-effort; the body tag block is canonical).
- Commit the `pr:` back-pointer onto the frozen `pr/*` branch — it goes on the source/base side.
- Squash or rebase a `pr/*` branch.
- Cherry-pick merge SHAs with `-m` — merge SHAs always route to the path-split fallback.
- **Update an open PR by building the change on a local/base/feature branch and leaving the PR head untouched (orphaning it).** To change an open PR you operate on its head branch: checkout → commit → push (Update mode). This is the DX-jn-8-026 lesson — PR #86 was rebuilt locally and had to be closed.

## Companion Skills

- **`pr-comments`** — service the review rounds this PR receives; calls back into step 6 for tag updates.
- **`base-push`** — publish local `<base>` to `origin/<base>` (`merge_into_branch_local` lives in `.claude/scripts/merge-helpers.sh`, sourced by both).
- **`todo`** — the `commits:` ledger this skill scopes from; its close step offers `/open-pr`.

---

**Skill Version**: 1.9.0
**Category**: Workflow, GitHub
_Version history: see [CHANGELOG.md](./CHANGELOG.md)._
