---
name: open-pr
description: Open a GitHub PR for finished work on a dedicated, frozen `pr/*` branch — never the shared base branch itself. By default the `pr/*` branch is cut from a SOURCE branch (the current/feature branch), the PR TARGET is selectable via `--into <branch>` (default the PR target, e.g. master), and the branch is brought up-to-date with the target before gate+create. The old ledger-scoped clean-diff mode is preserved as `--scoped`. Gates independently, auto-generates a reviewer guide + provenance body, tags the PR with its TODO id, writes the `pr:` back-pointer. PR creation itself is user-gated. Use when the user says "open a PR", "put this up for review on GitHub", or /todo's close step offers it.
---

# open-pr — dedicated, frozen PR branches

Open a GitHub PR whose head is a **dedicated, frozen `pr/<id>-<slug>` branch** — never the live shared base branch. The `pr/*` branch is cut from a **source branch** (default: the opening agent's current/feature branch; you can name any branch) and the PR **targets** a configurable branch (default the PR target, e.g. `master`; `--into <branch>` to target the base branch instead). Before review the `pr/*` branch is brought **up-to-date with its target** so it merges cleanly.

**Why a dedicated frozen branch:** a PR whose head is the live base branch mutates every time the fleet lands work — the diff accumulates unrelated changes, review guidance rots, and the PR can never be "done" (this is a real failure mode, not hypothetical). A `pr/*` branch is **frozen** — it's a snapshot taken at open time; later base-branch work doesn't touch it.

Two ways to populate it:

- **From-source (default)** — `pr/*` is cut from `<source-branch>` (default the current branch) and synced up-to-date with the target. The PR is that branch's work, measured against the target. **The target controls the diff:** `--into <base>` (the base branch) gives a clean *feature-only* diff (your commits on top of the base); the default `master` target measures against master — broader, because a base-rooted source branch carries the base's *other* unmerged work too (see Guards).
- **`--scoped <ID…>`** — the surgical mode: cut from `origin/<target>` and bring over ONLY the named TODO(s)' `commits:` (cherry-pick, or path-split on a merge SHA). The PR diff is exactly that TODO's work measured against the target — parallel TODOs can have parallel clean PRs. (This was the prior default.)

## When to Use

- The user says "open a PR for <ID>", "put this up on GitHub", "publish this for review".
- `/todo done` / `/todo continue` reached its close step and the user answered yes to "open a PR for this work?".
- `/afk --pr-on-close` finished a clean run.

**Do NOT use** to publish the base branch to origin (that's `/base-push`), or to land work into the local base (that's `/base-merge up`).

> **A coordinator instruction counts as the user** for invoking the skill — but the
> **create gate (step 5) is terminal-user-only**: PR creation publishes outward, so the
> title/body package is approved by the human (relayed through the coordinator is fine;
> implied is not).

## Invocation

```
/open-pr                           # from-source: cut pr/* from the current agent branch, target the default (master)
/open-pr <source-branch>           # cut pr/* from a named branch instead of the current one
/open-pr [<source>] --into <base>  # target the base branch (clean feature-only diff) instead of master
/open-pr --scoped <ID> [<ID2> …]   # surgical: cut from origin/<target> + cherry-pick the TODO(s)' commits:
Flags: --into <target> | --scoped | --draft | --reviewer <gh-user> | --label <l> … | --title <t> | --absorb <n>
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
# Is the target a published remote (e.g. master) or local-only (e.g. the base
# branch)? Drives whether step 2 syncs from origin/<target> or the local ref.
if git rev-parse --verify "refs/remotes/origin/$TARGET" >/dev/null 2>&1; then
  TARGET_REF="origin/$TARGET"; TARGET_REMOTE=1
else
  TARGET_REF="refs/heads/$TARGET"; TARGET_REMOTE=0   # local base branch, never pushed
fi
```

### 1. Fetch, then cut the branch — HARD REFUSALS first

This workflow's base skills never fetch, so the cached `origin/<target>` may be stale. Fetch the target before using it — but only when it's a published remote branch (a local-only target like the base branch has no origin ref to fetch; it's synced from the local ref in step 2):

```bash
[ "$TARGET_REMOTE" = 1 ] && git fetch origin "$TARGET"
```

**Refuse outright** (no override flag exists):

- A PR head of `<base>` or `<target>` — the live-base-headed-PR lesson, codified. The head is ALWAYS a fresh `pr/*` branch (so even when `<source>` is the base branch, you cut a fresh `pr/*` FROM it, never PR the live ref).
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

> **Ledger-timing precondition.** `commits:` is normally populated at TODO *close*, so opening a PR for **in-progress** work may find it empty. Before scoping, ensure the work commits are recorded — or pass them explicitly via `--commits <sha…>`, or derive them with `git log --reverse --format=%H --grep "<ID>" "origin/$TARGET..HEAD"`. **Do not** fall back to a raw branch-range (`origin/$TARGET..HEAD`): a long-lived feature/base branch carries unrelated history (the whole `<base>` lineage), so the range is not the scope — the ledger (or `--commits`) is.

- **Plain commits** → `git cherry-pick` onto the `pr/*` branch, oldest-first across all named IDs.
- **A merge SHA anywhere in scope is an explicit fallback trigger** — do NOT attempt `-m`/`-m 1` cherry-picks. Fall back to the **path-based split**: `git checkout <base> -- <paths>` for the TODO's files, with **dependency-closure discipline** — if a brought-over file imports something only present on `<base>`, the dependency's files join the set (whole files, never hybrid states), and the gates in step 3 prove closure. Same procedure as a dependency-closed path split of a shared branch.
- Cherry-pick conflicts that resolve trivially (context drift) are fine; entangled conflicts → switch to the path-based fallback rather than hand-weaving patches.

**Twin-content commits are expected, not a problem**: the `pr/*` branch re-creates content that also exists on `<base>`. Under the `<base> ⊇ <target>` invariant (the target only advances from base-derived content, and the base absorbs the target right after — step 7), the eventual merge-back is a clean no-op.

### 3. Regenerate artifacts, then gate independently

**First, regenerate generated artifacts on the `pr/*` branch and commit** — `pnpm gen:todos`, swagger, sql-types, and any other codegen the scoped change touches. A generated file produced against the *source* branch's state (the cherry-pick carries it verbatim) can drift on the master-rooted branch and trip the drift guard; regenerating reconciles it to the target's state + the scoped change. (This can stay hidden when the source and target generated state happen to match — regenerate so it never bites.)

Then run the project's CI-mirror gates **on the `pr/*` branch**. A scoped branch must be green **standing on the target alone** — this is what catches hidden dependencies on unreviewed base-branch content (this reliably catches real ones). Failures mean the dependency closure is incomplete (go back to step 2) or the work genuinely depends on another TODO — say so and ask whether to widen scope or block.

> **Distinguish your failures from pre-existing target defects.** A gate that reds on the `pr/*` branch **and also reds on the pristine `origin/<target>`** is a pre-existing defect, not this PR's to fix — record it in the provenance block and move on; do NOT block the PR or edit unrelated files to chase it. Only a failure *introduced by the scoped change* blocks. (e.g. a formatter or lint that already fails on a file the target had broken before this PR — not in your diff.) Note also that the push in step 5 re-runs the local pre-push hook (the full TS gate sweep); for a docs-only change that's heavier than the change warrants but is unavoidable through the hook — the in-place switch (step 1) is what keeps the env files present so it passes.

### 4. Compose the PR package

Auto-generate, then show the user (step 5):

- **Title**: conventional-commit style, referencing the ID.
- **Body**:
  - **TODO tag block** — `TODO: <ID>` + link to `docs/todos/<ID>.md` (or `completed/<ID>.md`), plan link. This block is the single tagging implementation other skills call back into (see Tagging below).
  - **Review guide derived from the plan** — focus files (the meat) vs skip list (generated artifacts, machinery), in the reviewer's terms.
  - **Provenance** — `plan_review:` record, diff-review GREEN (which agent, date), gates evidence (what ran, result). This block doubles as the agent-prepared provenance (the body is agent-drafted, user-approved at create).
  - **Merge guidance** — merge-commit only (never squash/rebase a branch whose commits are twins of base-branch commits; squash re-writes them and breaks the absorb).

Any *comment* `/open-pr` later posts on the PR (not the body) carries the same agent-authored marker `/pr-comments` uses (`<!-- agent-authored:pr-comments -->`), so a future review round can classify thread authorship consistently.
- **Labels**: `todo:<ID>`, plus labels derived from the TODO's `area`/`tags`, plus `--label` extras. A from-source PR spanning multiple TODOs (no single ID): label `batch`. **`gh pr create --label` errors on a label that doesn't exist in the repo** — before create, `gh label list` and `gh label create` the missing ones (or filter to existing). Labels are best-effort convenience; the body's **TODO tag block is the canonical linkage**, so never block create on a label gap.
- **Reviewers** from `--reviewer`.

### 5. Create — USER-GATED

Creating the PR **is an outward-facing post**: title, body (including internal provenance), labels, and reviewer requests all publish on create. **Show the user the complete package and get explicit approval BEFORE running:**

```bash
git push -u origin "pr/<…>"
gh pr create --base "$TARGET" --head "pr/<…>" --title … --body-file … [--draft] [--reviewer …] [--label …]
```

Same terminal-reviewer principle as `/pr-comments`' atomic posting — no auto-create, ever. `--draft` still gates (a draft is visible to the repo).

### 6. Tagging + the `pr:` back-pointer

**This skill owns TODO↔PR tagging** — one implementation, reused everywhere (`/pr-comments` calls back into this step when TODO state changes so the PR's tag block stays true):

- **First, return to the caller's branch**: `git checkout "$CALLER"` (the tree is clean — step 3 committed the regen and gates are read-only; assert if unsure). This is the freeze-critical return from step 1's timing note — do it here, before the commit below, so the `pr:` bump can't land on the frozen `pr/*` branch.
- Write `pr: <n>` into each in-scope TODO's frontmatter (active or completed), bump `updated`, run the TODO index generator (`node .claude/scripts/gen-todos.mjs` — validates the field), commit. **This commit lands on the source/base side** — the branch that owns the TODO ledger (e.g. `<base>` / the caller's branch you just returned to). **Never** commit it onto the frozen `pr/*` branch (that would un-freeze the reviewed content). On PR **merge**, append the target-branch merge SHA to the TODO's `commits:` so the ledger records where it shipped. `pr:` is single-valued — a second PR for the same TODO (e.g. a reopen shipped separately) overwrites it to the **latest**; earlier PRs stay discoverable via `commits:` and the PR-side `todo:<ID>` label.
- **From-source PRs spanning multiple TODOs**: the body lists every TODO whose `commits:` fall inside `<target>..<pr-tip>`; each of those TODOs gets `pr: <n>`. Same field, many writers — "which PR shipped this" stays answerable in both modes.
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

## Guards (warn, don't refuse)

- **From-source diff breadth (default mode).** A feature branch is usually `<base>`-rooted, so a `pr/*` cut from it and targeted at **master** diffs as "everything on the branch not in master" — which pulls in the base's *other* unmerged fleet work, not just yours (the live-base accumulation pattern). If you want a clean *feature-only* diff, target the base with **`--into <base>`** (diff = your commits on top of the base) or use **`--scoped <ID>`** for a surgical master-targeted PR. Warn when from-source + master target is chosen on a `<base>`-rooted source so the user picks deliberately.
- **A `--into <base>` PR advances `origin/<base>` when merged — actively discourage it while the base is frozen.** Targeting the base branch means the GitHub merge writes `origin/<base>`, which is otherwise advanced ONLY by the human-gated `/base-push`, and may be the SHA a long-lived PR is frozen at. While the standing "keep `origin/<base>` frozen" rule is in force, **recommend against `--into <base>`** (use the local `/base-push` flow to land into the base, or target `master`) and require an explicit user confirmation before creating one — don't treat it as a neutral option. Once the base is intentionally unfrozen this softens back to a plain heads-up.
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

## Companion Skills

- **`pr-comments`** — service the review rounds this PR receives; calls back into step 6 for tag updates.
- **`base-push`** — publish local `<base>` to `origin/<base>` (`merge_into_branch_local` lives in `.claude/scripts/merge-helpers.sh`, sourced by both).
- **`todo`** — the `commits:` ledger this skill scopes from; its close step offers `/open-pr`.

---

**Skill Version**: 1.4.0
**Category**: Workflow, GitHub

## Changelog

- **1.4.0** — **From-source rooting is now the default.** `pr/*` is cut from a
  **source branch** (default the opening agent's current branch; name any branch
  as the first arg) and synced **up-to-date with a selectable target**
  (`--into <branch>`, default the configured PR target / `master`); the old
  ledger-scoped/target-rooted mode is preserved as **`--scoped`** (replacing the
  prior `--snapshot`/default split). Step 0 resolves both source and target (and
  whether the target is a published remote or a local-only base); step 1 fetches
  the target only when remote and cuts from the source; step 2 gains the
  from-source target merge (the scoped cherry-pick/path-split moves under
  `--scoped`). New Guards flag the two consequences: from-source + `master`
  target on a `<base>`-rooted branch yields a broad diff (use `--into <base>` for
  a clean feature-only diff, or `--scoped` for a surgical PR), and a
  `--into <base>` PR **advances `origin/<base>` on merge** — actively discouraged
  while the base is frozen + requires explicit confirmation. Step 7 notes that
  an `--into <base>` PR has no absorb dance (reconcile local `<base>` with the
  advanced remote instead).
- **1.3.0** — (merge-helper hardening) `--absorb` (step 7) now **routes
  `merge_into_branch_local`'s return code**: only on `0` does it write the ledger
  + delete the `pr/*` branch; on any non-zero it STOPS (the absorb didn't land,
  `<base> ⊇ <target>` not restored) and never deletes the frozen reviewed branch.
  Sources the helper from `.claude/scripts/merge-helpers.sh` (extracted from
  `base-push`).
- **1.2.0** — First end-to-end dogfood hardening: the `pr/*` branch is
  now cut **in place** (`git checkout -b … origin/<target>` in the caller's
  worktree, return with `git checkout "$CALLER"`) instead of a transient
  worktree — simpler, and it keeps untracked env files (`server/.env`) present
  so the pre-push hook's env-dependent gates pass (the worktree lacked them and
  failed at push). Added: `commits:`-ledger timing precondition + `--commits`/
  `git log --grep` fallback (the ledger is empty mid-work); mandatory
  **artifact regeneration after cherry-pick** before gating (a generated file
  drifts on the master-rooted branch); **gate-vs-target baseline** (a failure
  also present on `origin/<target>` is pre-existing, not this PR's); **label
  existence** handling (`gh label create` missing, or filter — body tag block is
  canonical); `pr:` back-pointer explicitly commits on the **source/base side**,
  never the frozen branch. The transient worktree remains only on `--absorb`.
- **1.1.0** — Review-round dogfood: posted comments carry the shared
  `agent-authored:pr-comments` marker so `/pr-comments` rounds can classify
  thread authorship; provenance block noted as the agent-prepared record.
- **1.0.0** — Initial: frozen `pr/*` branches off the PR target, scoped-from-ledger
  (default) + `--snapshot` modes, merge-SHA → path-split rule, independent gating,
  user-gated create, TODO tagging + `pr:` back-pointer ownership, `--absorb`,
  `<base> ⊇ <target>` guards. (Codifies the lessons of a PR opened with the live base branch as its head.)
