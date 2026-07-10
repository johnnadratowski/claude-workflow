# Fleet base-branch workflow — shared model

The `base-*` skills (`base-merge`, `base-push`, `base-pr`, `base-test`) all coordinate the
fleet around one shared base branch. They share a single conceptual model — the configurable
base branch, the local-first / origin-write-only invariant, and the canonical transient-worktree
merge helper. **This doc is the one place that model lives; each skill links here instead of
restating it, and keeps only its own procedure, flags, and refusals.**

## At a glance — which skill does what

| Skill | Network? | What it does |
| ----- | -------- | ------------ |
| **`base-merge`** | none | Local-only sync of the base ref ↔ the current branch — `down` (base → branch), `up` (branch → base via the helper), or both. No fetch, no push. |
| **`base-push`** | push only | Advance local `<base>` from the current branch (same helper), then **publish** `git push origin <base>`. The **only** skill that pushes `origin/<base>`. |
| **`base-pr`** | none | PR-style review of what's new on local `<base>` since the last review, on the dedicated `<base>-review` snapshot; audits, applies fixes, promotes into local `<base>`. |
| **`base-test`** | none (push never) | Run every TS/JS quality gate against a target branch/SHA/PR, optionally with local `<base>` merged in first. Reports; never commits/pushes/promotes. |

The PR-lifecycle skills (`/open-pr`, `/pr-comments`) make their own deliberate, user-gated origin
writes — `pr/*` branches and comment posts — and **never** touch `origin/<base>`.

## The configurable base branch

The base branch is **configured, not hardcoded.** `WORKFLOW_BASE_BRANCH` is read from
`.claude/workflow.config` (currently `<base>`; framework default `main`) by sourcing
`.claude/scripts/_config.sh`, which also exports `WORKFLOW_MAIN_PATH` (the canonical clone that
anchors the helper's transient worktrees; default: git toplevel). Env values win over the config
file, so a caller can override per-invocation. Saying "merge <base>" / "push <base>" / "review <base>"
/ "test <base>" invokes the corresponding `base-*` skill against the configured base.

Every base-* skill begins by sourcing config + the merge helpers:

```bash
source "$(git rev-parse --show-toplevel)/.claude/scripts/_config.sh"      # WORKFLOW_BASE_BRANCH, WORKFLOW_MAIN_PATH
source "$(git rev-parse --show-toplevel)/.claude/scripts/merge-helpers.sh" # merge_into_branch_local, regen_merged_artifacts
```

`merge-helpers.sh` only defines functions (no side effects), so sourcing it is always safe.

## Local-first, origin-write-only

Local `refs/heads/<base>` is the **single coordination ref for the whole fleet** — every worktree
on the machine shares one `.git`, so a peer's commit is visible (and mergeable) as a local ref the
moment it's committed, with **no push required**. `origin/<base>` is only a published snapshot that
advances when — and only when — someone runs `/base-push`.

Consequences every skill relies on:

- **No fetch / no pull path.** None of these skills reads from origin; the old `base-pull` was
  removed when the workflow moved to local-first. The only origin write is `/base-push`'s publish.
- **Audit / test / merge ranges come from local `<base>`**, never `origin/<base>` — sourcing them
  from origin would make unpublished local commits invisible (they'd slip past review/tests until
  published). Any commit on local `<base>` is in scope the moment it exists.
- **Drift is normal.** Local `<base>` is usually **ahead** of `origin/<base>` (work assembled
  locally, not yet published); a non-zero "behind" count means someone published out of band — it's
  surfaced for visibility, reconciled manually, never force-resolved.

## `master ⊆ <base>` invariant

The PR-target branch (`WORKFLOW_PR_TARGET_BRANCH`, here `master`) only ever advances via PRs cut
from base content on `pr/*` branches — these skills never merge `master` "down." Work flows
**feature branch → local `<base>` → (PR) → master**, so local `<base>` is always a superset of —
at or ahead of — `master`. The base carries everything `master` has plus in-flight, unpublished
work; that's by design and is why review/tests source their ranges from local `<base>`.

## The transient-worktree merge helper (canonical, local-only)

`merge_into_branch_local` is the single mechanism every skill uses to advance the shared base
branch — `/base-push`, `/base-merge` (`up`), `/base-test` (its pre-test base merge), and
`/open-pr` (`--absorb`). It is defined **once** in [`.claude/scripts/merge-helpers.sh`](../scripts/merge-helpers.sh)
and **sourced** by every caller (see the source block above). (It previously lived inline in
`base-push` as prose-only code, which meant callers that never sourced `base-push` — e.g.
`base-test`, which calls `regen_merged_artifacts` — hit `command not found` mid-merge. One sourced
script removes that whole class of drift.)

It is **purely local** — no `fetch`, no `push`. `origin` is never touched inside the helper;
publishing is a separate explicit step only `/base-push` performs. It attaches a short-lived
transient worktree to local `refs/heads/<base>` (branch-attached, **not** detached), merges the
local source ref in with `--no-ff`, reconciles `merge=ours` artifacts, commits on the local ref,
and removes the worktree — so the merge lands on local `<base>` and the **caller's own worktree
HEAD is never disturbed.**

### Signature + return-code contract — `merge_into_branch_local TARGET SOURCE_REF MSG`

Every caller MUST route on these. **The conflict (2) vs post-merge-failure (3) split is
load-bearing** — they used to be a single overloaded `2`, so a clean merge whose regen failed told
the user to "resolve conflicts" that didn't exist and look for a path that was never printed.

| Code | Meaning | Worktree | What the caller does |
| ---- | ------- | -------- | -------------------- |
| `0` | success; local `TARGET` advanced | cleaned up | continue |
| `1` | setup / `worktree add` failure — **no merge attempted** | none left (helper runs `worktree prune` to self-heal a dangling registration) | stop; surface (base checked out elsewhere, or a stale transient worktree — see recovery below) |
| `2` | **merge conflict** | **preserved at printed path** (markers) | stop; the user resolves there, regenerates (`node scripts/gen-todos.mjs`), commits, removes |
| `3` | **post-merge failure** — merge was CLEAN but regen or commit failed | **preserved at printed path** (already merged) | stop; the user fixes the regen/commit there, commits, removes — there is nothing to "resolve" |

`regen_merged_artifacts WT` (also exported by the script) reconciles the `merge=ours` artifacts on
the materialized merged tree and stages them so they fold into the merge commit: `docs/TODO.md` +
back-links (always; pure-node), and the **role-permissions seed** when the merge actually changed
`types/role-permissions.ts` (it borrows the main clone's `tsx` so it works even in a bare transient
worktree; if the matrix changed but no `tsx` is reachable it fails loudly rather than commit a stale
seed). It returns non-zero on failure, which the helper maps to code `3`. **Every auto-committing
merge path that brings base content in** — this helper, `/base-merge`'s down-merge, `/base-test`'s
pre-test merge — MUST run this reconcile (the in-place down-merges call it directly; the helper calls
it internally).

Design decisions baked into the helper:

- **`SOURCE_REF` is a local branch, never `origin/<branch>`.** Coordination is purely local; a
  peer's work is mergeable as soon as it's *committed* (shared `.git`), with no push required.
- **The merge commit lands on `refs/heads/TARGET` directly** because the transient worktree is
  branch-attached (no `--detach`). The caller's own worktree HEAD is never touched.
- **`--no-ff` is mandatory** — matches the repo's merge topology.
- **`--no-commit` then regenerate then commit** so the `merge=ours` artifacts are reconciled into
  the merge commit and the drift-guard passes.
- **Conflicts (and post-merge failures) leave the transient worktree intact** at a printed path —
  the failure mode is "an extra directory to resolve/finish," never "the caller's tree is mid-conflict."
- **No `origin` inside the helper** — publishing is `/base-push`'s separate final step.

### Preconditions + recovery

- **`TARGET` must NOT be checked out in any worktree.** That single constraint also acts as a
  natural mutex, serializing merges into `TARGET`. For `<base>` / `<base>-review` / `<base>-test`
  this is the project convention; for an unusual `--base` passed to `/base-pr`, verify the base
  isn't checked out first.
- **Only a checkout of the literal `TARGET` branch breaks this** — a worktree on any *other* branch
  (a coordinator worktree on a dedicated `<base>-cc` branch, or detached at `origin/<base>`) is
  harmless. **Never check out the literal base branch in a worktree:** it makes `worktree add <base>`
  fail, silently breaking the merge path for every agent. Ride a `<base>-cc` branch or a detached ref
  for a base-tracking worktree — see `add-worktree`.
- **Stale transient worktree (return 1 after a crash):** a crashed merge can leave a worktree
  attached to the base, blocking everyone. The helper runs `git worktree prune` on a failed add to
  self-heal a dangling registration; if a live checkout lingers, recover with
  `git -C "$WORKFLOW_MAIN_PATH" worktree list` to find the `wf-merge-local-*` path, then
  `git -C "$WORKFLOW_MAIN_PATH" worktree remove --force <path>` (and `git worktree prune`).
