---
name: open-pr
description: Open a GitHub PR for finished work on a dedicated, frozen `pr/*` branch rooted at the repo's PR-target branch (e.g. master) — never the shared base branch itself. Scopes the diff from the TODO ledger's `commits:` (or snapshots a whole branch), gates it independently, auto-generates a reviewer guide + provenance body, tags the PR with its TODO id, and writes the `pr:` back-pointer. PR creation itself is user-gated. Use when the user says "open a PR", "put this up for review on GitHub", or /todo's close step offers it.
---

# open-pr — dedicated, frozen PR branches

Open a GitHub PR whose head is a **dedicated `pr/<ID>-<slug>` branch** cut from the PR-target branch (`origin/<target>`, e.g. `origin/master`) — never the shared base branch (`<base>`, e.g. `main`) or the target itself.

**Why this skill exists:** a PR whose head is the live base branch mutates every time the fleet lands work — the diff accumulates unrelated changes, review guidance rots, and the PR can never be "done" (this is a real failure mode, not hypothetical). A `pr/*` branch is **frozen** — it contains exactly what this skill put on it, and later base-branch merges don't touch it.

The work's **source** is always the base branch or a feature branch (`<base>-*`); rooting the PR branch at the target only controls **what the diff is measured against**. Two modes:

- **Scoped (default)** — bring over ONLY the in-scope work, selected from the TODO ledger's `commits:` frontmatter. The PR diff is exactly that TODO's work; parallel TODOs can have parallel PRs.
- **`--snapshot [<ref>]`** — cut the branch at `<ref>`'s (default: current branch's) SHA. The PR is everything pending vs the target, frozen at that moment. For the rare "publish the whole batch" case.

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
/open-pr <ID> [<ID2> …]            # scoped from the TODO(s)' commits: ledger
/open-pr --snapshot [<ref>]        # freeze <ref> (default: current branch) as the PR
Flags: --draft | --reviewer <gh-user> | --label <l> … | --title <t> | --absorb <n>
```

## Execution Steps

### 0. Config + target resolution

```bash
source "$(git rev-parse --show-toplevel)/.claude/scripts/_config.sh"
# PR target: configurable, else the repo's default branch.
TARGET="${WORKFLOW_PR_TARGET_BRANCH:-$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')}"
[ -n "$TARGET" ] || TARGET=$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name)
```

### 1. Fetch, then cut the branch — HARD REFUSALS first

This workflow's base skills never fetch, so the cached `origin/<target>` may be stale. Fetch explicitly before cutting:

```bash
git fetch origin "$TARGET"
```

**Refuse outright** (no override flag exists):

- A PR head of `<base>` or `<target>` — the live-base-headed-PR lesson, codified. The head is ALWAYS a fresh `pr/*` branch.
- A dirty working tree (commit or stash first — the skill switches branches).

Branch name: `pr/<id-lowercased>-<slug>` (scoped; multi-ID uses the first ID + a joint slug) or `pr/batch-<date>-<slug>` (snapshot).

- **Scoped**: `git branch "pr/<…>" origin/$TARGET`
- **Snapshot**: `git branch "pr/<…>" <ref>` — cut AT the source SHA; the live ref keeps moving, the PR branch doesn't.

### 2. Scope the content (scoped mode only)

Read each named TODO's `commits:` frontmatter (active or `completed/`). That list is the scope.

- **Plain commits** → `git cherry-pick` onto the `pr/*` branch, oldest-first across all named IDs.
- **A merge SHA anywhere in scope is an explicit fallback trigger** — do NOT attempt `-m`/`-m 1` cherry-picks. Fall back to the **path-based split**: `git checkout <base> -- <paths>` for the TODO's files, with **dependency-closure discipline** — if a brought-over file imports something only present on `<base>`, the dependency's files join the set (whole files, never hybrid states), and the gates in step 3 prove closure. Same procedure as a dependency-closed path split of a shared branch.
- Cherry-pick conflicts that resolve trivially (context drift) are fine; entangled conflicts → switch to the path-based fallback rather than hand-weaving patches.

**Twin-content commits are expected, not a problem**: the `pr/*` branch re-creates content that also exists on `<base>`. Under the `<base> ⊇ <target>` invariant (the target only advances from base-derived content, and the base absorbs the target right after — step 7), the eventual merge-back is a clean no-op.

### 3. Gate independently

Run the project's CI-mirror gates **on the `pr/*` branch**. A scoped branch must be green **standing on the target alone** — this is what catches hidden dependencies on unreviewed base-branch content (this reliably catches real ones). Failures mean the dependency closure is incomplete (go back to step 2) or the work genuinely depends on another TODO — say so and ask whether to widen scope or block.

### 4. Compose the PR package

Auto-generate, then show the user (step 5):

- **Title**: conventional-commit style, referencing the ID.
- **Body**:
  - **TODO tag block** — `TODO: <ID>` + link to `docs/todos/<ID>.md` (or `completed/<ID>.md`), plan link. This block is the single tagging implementation other skills call back into (see Tagging below).
  - **Review guide derived from the plan** — focus files (the meat) vs skip list (generated artifacts, machinery), in the reviewer's terms.
  - **Provenance** — `plan_review:` record, diff-review GREEN (which agent, date), gates evidence (what ran, result).
  - **Merge guidance** — merge-commit only (never squash/rebase a branch whose commits are twins of base-branch commits; squash re-writes them and breaks the absorb).
- **Labels**: `todo:<ID>`, plus labels derived from the TODO's `area`/`tags`, plus `--label` extras. Snapshot mode: label `batch`.
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

- Write `pr: <n>` into each in-scope TODO's frontmatter (active or completed), bump `updated`, run the TODO index generator (`node .claude/scripts/gen-todos.mjs` — validates the field), commit. On PR **merge**, append the target-branch merge SHA to the TODO's `commits:` so the ledger records where it shipped. `pr:` is single-valued — a second PR for the same TODO (e.g. a reopen shipped separately) overwrites it to the **latest**; earlier PRs stay discoverable via `commits:` and the PR-side `todo:<ID>` label.
- **Snapshot/batch PRs**: the body lists every TODO whose `commits:` fall inside `<target>..<SHA>`; each of those TODOs gets `pr: <n>`. Same field, many writers — "which PR shipped this" stays answerable in both modes.
- **No good TODO id?** Tagging is optional — but the PR is then **clearly marked agent-created-without-TODO**: label `agent-no-todo` + a body banner line. If the work plausibly warrants a TODO, RECOMMEND minting one to the user before creating.

### 7. Post-merge absorb — `--absorb <n>`

Offered automatically when `gh pr view <n>` shows the PR merged (and runnable later as `/open-pr --absorb <n>`):

```bash
git fetch origin "$TARGET"
merge_into_branch_local "$WORKFLOW_BASE_BRANCH" "origin/$TARGET" \
  "Merge origin/$TARGET into $WORKFLOW_BASE_BRANCH (absorb PR #<n>)"
```

(`merge_into_branch_local` is the canonical transient-worktree helper defined in `base-push/SKILL.md`.) This restores `<base> ⊇ <target>` immediately so future twin-content merges stay no-ops. **It never pushes `origin/<base>`** — publishing the base remains `/base-push`'s human-gated job. Then update the TODO ledger (step 6's merge bookkeeping) and delete the remote `pr/*` branch (a repo with delete-branch-on-merge enabled — a repo setting, not configured by this skill — already did; otherwise `git push origin --delete pr/<…>` — ask first, it's a remote deletion).

## Guards (warn, don't refuse)

- An in-scope TODO has no review record (`plan_review:` missing/skipped on a complex plan, or no diff-review GREEN evidence) → warn; the user may still proceed (the PR's provenance section then says so honestly).
- `<base> ⊉ <target>` (`git merge-base --is-ancestor origin/$TARGET <base>` fails) → warn: someone landed to the target without an absorb; recommend running `--absorb` first so twin detection stays clean.
- **Target advanced while a PR is open** → merge `origin/<target>` into the `pr/*` branch (**merge, not rebase** — it's published) and re-run the gates before re-requesting review.

## What This Skill Will NOT Do

- Use `<base>` or `<target>` as a PR head — refused, no override.
- Run `gh pr create` (or push the `pr/*` branch) before the user approves the package.
- Push `origin/<base>` — only `/base-push` does that, and only human-gated.
- Squash or rebase a `pr/*` branch.
- Cherry-pick merge SHAs with `-m` — merge SHAs always route to the path-split fallback.

## Companion Skills

- **`pr-comments`** — service the review rounds this PR receives; calls back into step 6 for tag updates.
- **`base-push`** — publish local `<base>` to `origin/<base>` (defines `merge_into_branch_local`).
- **`todo`** — the `commits:` ledger this skill scopes from; its close step offers `/open-pr`.

---

**Skill Version**: 1.0.0
**Category**: Workflow, GitHub

## Changelog

- **1.0.0** — Initial: frozen `pr/*` branches off the PR target, scoped-from-ledger
  (default) + `--snapshot` modes, merge-SHA → path-split rule, independent gating,
  user-gated create, TODO tagging + `pr:` back-pointer ownership, `--absorb`,
  `<base> ⊇ <target>` guards. (Codifies the lessons of a PR opened with the live base branch as its head.)
