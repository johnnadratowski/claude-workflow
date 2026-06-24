---
name: todo
description: Track substantive work as one file per TODO under docs/todos/ with structured frontmatter, a stable namespaced ID, a generated docs/TODO.md index, and a completed/ archive. Drives the full lifecycle — add → plan → implement → doc-sync (incl. architecture) → review → close — and regenerates the index after every mutation. The TODO files are the tracker (no external ticket system). Use for any feature, fix, refactor, or investigation.
---

# todo — file-per-TODO lifecycle

## Purpose

The TODO system tracks every substantive unit of work as a **file-per-TODO** with
structured frontmatter (status, priority, area, milestone, dates, dependencies),
a **stable ID** (`AREA-<NS>-<lane>-NNN`), a **generated published index**, and a **completed
archive** (closed TODOs are moved, never deleted). This skill is how you create,
move through, query, and close those TODOs. **The TODO files ARE the tracker** — there
is no separate external ticketing system to keep in sync.

**Substantive work runs through a TODO.** When the user asks for a feature, fix,
refactor, or investigation, the flow is: **create the TODO → plan → implement →
doc-sync → review → close** (archive + reference the ID in the commit). Trivial edits —
typos, one-line tweaks, formatting — are exempt and committed directly.

## File model (source of truth)

```
docs/todos/
  milestones.json          Canonical taxonomy: milestones→version, areas→prefix, priorities, statuses.
  README.md                Explains the system + frontmatter shape.
  <ID>.md                  One active/open TODO (status: open | in-progress | blocked | deferred).
  completed/
    <ID>.md                Closed TODO (status: done | cancelled). MOVED here on close, never deleted.
docs/TODO.md               GENERATED index — never hand-edit. `node .claude/scripts/gen-todos.mjs` rebuilds it.
docs/todo_plans/<slug>.md  Optional per-TODO implementation plan (linked from the TODO's `plan:` field).
docs/specs/NNN-<slug>.md   Optional feature specs (from /define-product). A TODO may link one via `spec:`.
```

Each TODO file is frontmatter + body:

```markdown
---
id: SEC-jn-8-001             # AREA-<NS>-<lane>-NNN, stable forever (never changes, even on defer)
title: Short imperative title
status: open                 # open | in-progress | blocked | deferred | done | cancelled
priority: high               # critical | high | medium | low
area: security               # must match an area in milestones.json; prefix must match the id
milestone: pre-release       # must match a milestone key in milestones.json
created: 2026-01-01           # ISO date, set once
updated: 2026-01-01           # ISO date, bumped on every change
tags: []                     # free-form labels
blocked_by: []               # [other-ids] — must resolve to real TODOs
plan:                        # optional: docs/todo_plans/<slug>.md
plan_review:                 # set by the plan-review gate: "green (<agent>, YYYY-MM-DD)" | "skipped (<reason>)"
                             # validated by gen-todos when present; complex plans get one before implementation
spec:                        # optional: docs/specs/NNN-<slug>.md (if the project uses specs)
pr:                          # set by /open-pr: the GitHub PR number that ships this work (validated when present)
# on close, the archived file also carries:
# completed: 2026-01-02
# commits: [<sha>, …]
---

<!-- gen:todos:backlink (managed — do not edit) -->
[← Back to the TODO index](../TODO.md)
<!-- /gen:todos:backlink -->

Body — the full description, scope, links. Preserve detail; this is the record.
```

**Cross-links are generator-managed — never hand-write them.** `node .claude/scripts/gen-todos.mjs`
owns both directions (forward from the index, back-link block in each file) and is
idempotent. Write your TODO body below the managed block and let the generator place it.

The **canonical taxonomy** (valid areas/prefixes, priorities, milestones→version,
statuses) lives in `docs/todos/milestones.json`. Read it before assigning fields; the
generator validates every file against it. (`/define-product` and `/define-architect`
help tailor the taxonomy + milestones to the project.)

## ID allocation

`AREA-<NS>-<lane>-NNN`: the area's prefix from `milestones.json` + a **per-engineer
namespace** `<NS>` + **this worktree's lane number** + a zero-padded 3-digit sequence —
**each its own dash-delimited segment**, scoped per (area, NS, lane). Example: `SEC-jn-8-001`
(namespace `jn`, lane 8, sequence 001).

> **Why the lane is its own segment.** It used to be concatenated onto the sequence
> (`SEC-jn-8001`), which aliases once lanes reach two digits: an end-unanchored scan for
> lane 1 (`…-1[0-9]{3}`) also matched lane 10's `…-10001`. The dash makes the lane
> unambiguous from the sequence at ANY width — `jn-1-` ≠ `jn-10-` ≠ `jn-100-`.

**Two namespacing axes, both needed:**
- **`<NS>` (per-engineer)** guards against collisions *across clones* — a second engineer
  mints on their own machine with no shared lock, so without a per-engineer namespace their
  `SEC-0001` would collide with yours and a TODO could be lost on merge.
- **`<lane>` (per-worktree)** guards against collisions *within one engineer's machine* —
  parallel worktrees all share one git identity (so the same `<NS>`), and mint in parallel
  with no lock; the lane keeps them disjoint. NS does not subsume the lane, nor vice-versa.
  The generator still validates uniqueness as a backstop for the rare same-(NS, lane)
  parallel mint.

**Step 1 — namespace `NS`:** resolved by `_config.sh` as `WORKFLOW_TODO_NS`. Precedence:
the explicit per-clone knob (**recommended** — set `WORKFLOW_TODO_NS` in the gitignored
`.claude/workflow.config.local`, e.g. `WORKFLOW_TODO_NS="jn"`) → else the full local-part
of `git config user.email` (lowercased, alnum-only — collision-safe but long, so most
engineers set the short knob) → else `0`.

```bash
ROOT=$(git rev-parse --show-toplevel)
source "$ROOT/.claude/scripts/_config.sh"     # exports WORKFLOW_TODO_NS
NS="$WORKFLOW_TODO_NS"
```

**Step 2 — lane number:** read `WORKFLOW_TODO_LANE` (set per-worktree in
`.claude/workflow.config`); **if unset, use `0`**. Give each parallel worktree a distinct
lane to make cross-worktree collisions structurally impossible.

```bash
LANE="${WORKFLOW_TODO_LANE:-0}"
```

**Step 3 — next sequence:** scan existing IDs across BOTH `docs/todos/` and
`docs/todos/completed/` for that prefix **and this NS and lane**, take `max + 1` (start `001`):

The scan is **end-anchored** and accepts both the new dash form and any legacy concatenated
id for the same lane (`-?` = optional lane dash), so the sequence stays continuous across the
format change and a one-digit lane never grabs a two-digit lane's ids:

```bash
PREFIX=SEC   # the area's prefix from milestones.json (SEC, DX, …)
last=$(ls docs/todos docs/todos/completed 2>/dev/null \
  | sed 's/\.md$//' \
  | grep -oE "^${PREFIX}-${NS}-${LANE}-?[0-9]{3}$" \   # anchored: lane 8 ≠ lane 80; `-?` spans old+new
  | grep -oE '[0-9]{3}$' | sort -n | tail -1)          # the 3-digit seq is always the last group
NEXT=$(printf '%03d' $(( 10#${last:-000} + 1 )))        # 10# forces base-10 (ignore leading-zero octal)
# mint:  ${PREFIX}-${NS}-${LANE}-${NEXT}   →  e.g. DX-jn-8-006 (none yet ⇒ ${PREFIX}-${NS}-${LANE}-001)
```

So engineer `jn` in lane 8 mints `DX-jn-8-006`; lane 10 mints `SEC-jn-10-001`; engineer `pk`
in lane 0 mints `SEC-pk-0-001` — never the same string as `jn`'s, across machines OR
worktrees, **at any lane width**.

**Legacy IDs grandfather** — bare `AREA-NNN` (`SEC-002`), legacy lane-concatenated
`AREA-<lane>NNN` (`DX-8011`), and the prior NS-concatenated `AREA-<NS>-<lane>NNN`
(`DX-jn-8001`) all stay valid and untouched — `ID_RE`
(`/^[A-Z]+-([a-z0-9]+-)?(\d+-)?\d{3,}$/`) accepts every form (the optional `(\d+-)?` is the
new lane segment; absent, the `\d{3,}` tail absorbs an old concatenated lane+seq). Step 3's
`-?` reads max-seq across old and new forms, so the sequence continues unbroken. **Never
renumber an existing ID.** IDs are **immutable** — deferring, blocking, or re-scoping never
changes the ID, so commit references stay valid forever.

## After ANY mutation: keep the index live + validate

Every verb that creates/edits/moves a TODO file MUST, before finishing:

1. Run `node .claude/scripts/gen-todos.mjs` — regenerates `docs/TODO.md` AND validates all
   frontmatter (unique IDs, valid enums, prefix↔area match, `blocked_by` resolves, archive
   placement). A non-zero exit means you broke something — fix it.
2. Stage the TODO file(s) **and** the regenerated `docs/TODO.md` together.

Wire the generator (`--check`) into CI so a stale index or invalid frontmatter fails the build.

## Commit-reference convention

A commit that creates, advances, or closes a TODO references its ID — in the subject tail
(`feat(server): add per-state deposit gate (FEAT-001)`) or as a trailer
(`Refs: FEAT-001` in progress / `Closes: FEAT-001` on completion). This is how `git log`
ties back to the TODO record.

## Verbs

Parse the skill arguments to pick a verb. The lifecycle verbs (`add` → `start` →
`continue`/`done`) are the spine; the rest are management.

### `add` — create a TODO
Triggers: "add a todo …", or the FIRST step of any substantive work request.
1. Read `docs/todos/milestones.json` for valid areas/priorities/milestones.
2. Decide `area` (→ prefix), `priority` (auto-suggest from area, confirm), `milestone`,
   `tags`. If a `docs/specs/` spec covers this work, set `spec:` to its path (auto-detect via
   the title matching `[Ss]pec[\s_-]?0*(\d+)` against `docs/specs/*.md`).
3. Mint the next `AREA-<NS>-<lane>-NNN` (resolve NS + lane + scan existing — see ID allocation).
4. Write `docs/todos/<ID>.md` with frontmatter (`status: open`, `created`/`updated` = today)
   + body.
5. Run the generator; report the new ID.

> For a non-trivial change the user just asked you to *do*, `add` is step 1 — mint the
> TODO, then proceed to implement under it, then close it. Don't ask "should I make a TODO"
> for substantive work; just do it and tell them the ID.

### `start` — open → in-progress
Set `status: in-progress`, bump `updated`, run the generator. For complex work, draft a plan
in `docs/todo_plans/<slug>.md` and set the `plan:` field (see the planning workflow) — then
run the **plan-review gate** (planning workflow step 3) before any implementation starts.

### `<ID>` / `do the <keyword> todo` — plan + implement
Locate the TODO (by ID, or by searching titles/bodies for the keyword), then run the full
planning + execution workflow below. (If multiple match, ask which one. If the matched TODO is
already mid-lifecycle — in-progress and reviewed — surface that and ask before re-executing.)

### `continue` — finalize after review (idempotent)
Triggers: `/todo continue`, "continue", "finalize", "review done", "ship it".
Resume the post-review finalize. **Idempotent** — re-running after a partial failure resumes
from the correct step by inspecting git state:
1. **Promote** — `/base-push` (or `/base-merge up` if not publishing yet). If local `<base>`
   already contains this work (check `git log <base> --grep "<ID>"` / the merge SHA), skip.
   On `/base-push` failure: stop, leave the TODO as-is, user fixes and re-runs.
2. **Notify the testing agent** (optional) — `WORKFLOW_TESTING_AGENT` from config, or ask;
   `agent-send <tester> --stdin` with the merge SHA + plan-derived context. Skip on "no tester".
3. **Close** — `done` the TODO (archive + `commits:` + `Closes:`). If it's already in
   `completed/`, report "already shipped" and exit cleanly.

### `done` / `cancel` — close a TODO (archive, never delete)
1. Set `status: done` (or `cancelled`), add `completed: <today>` and (for `done`)
   `commits: [<sha>…]`. For `cancel`, add a one-line reason to the body.
2. **Move** the file `docs/todos/<ID>.md` → `docs/todos/completed/<ID>.md` (`git mv`).
3. Run the generator; stage the moved file + the regenerated index.
4. The closing commit references the ID (`Closes: <ID>`). `cancel` does NOT revert committed
   code — that's a separate `git revert` / follow-up TODO.
5. **Offer a GitHub PR** (for `done`): ask the user "open a PR for this work?" → yes invokes
   `/open-pr <ID>` (dedicated frozen `pr/*` branch scoped from this TODO's `commits:`; that
   skill writes the `pr:` back-pointer). Skip the ask when a `pr:` already exists or the work
   is internal-only. Under `/afk`, asked only via its `--pr-on-close` flag.

### `defer <ID> <milestone>` — park for a later milestone
Set **`status: deferred`** AND `milestone` to the new value, bump `updated`, optionally add a
body note. ID unchanged. Run the generator.

### `block <ID> <blocker-ID>` / `unblock <ID>`
`block`: set `status: blocked` and add the blocker's **ID** to `blocked_by` (IDs only — a
free-text reason goes in the body). `unblock`: **clear the resolved blocker from `blocked_by`**
AND set status back to `open`/`in-progress` (the index renders the ⛔ badge whenever
`blocked_by` is non-empty, so clearing it is required). Run the generator.

### `reopen <ID>` — a closed TODO regressed
`git mv` it back from `completed/` to `docs/todos/`, set `status: open`, clear
`completed`/`commits`, add a body note on the regression. Run the generator.

### `show <ID>` / `list [--milestone X] [--priority Y] [--area Z] [--status S] [--tag T]`
`show`: print the TODO file. `list`: read `docs/todos/` frontmatter, filter, print a table
sorted by milestone → priority. (Or just show the generated `docs/TODO.md`.)

### Editing fields no verb covers
Changing `priority`, `tags`, `plan`, `spec`, or the body has no dedicated verb — hand-edit the
frontmatter, bump `updated`, then run the generator.

## Planning + execution workflow (for non-trivial work)

1. **Load the project docs corpus** that informs the work — the best-practices doc(s),
   `docs/architecture.md`, `docs/security.md`, `docs/testing.md`, `docs/api-conventions.md`,
   `docs/product.md`, and the relevant `CLAUDE.md`. The `2>/dev/null` form tolerates whatever
   the project ships:
   ```bash
   cat docs/best-practices.md docs/architecture.md docs/security.md docs/testing.md \
       docs/api-conventions.md docs/product.md 2>/dev/null
   ```
   If the TODO links a `spec:` (or the title matches a spec), also load that spec and map its
   **acceptance criteria** to implementation steps. Cite the rules the work touches.
2. **Plan** (complex work): use `EnterPlanMode` → draft the plan inline (analysis +
   best-practices/architecture/security citations + spec AC mapping + steps) → `ExitPlanMode`
   for approval → write it to `docs/todo_plans/<slug>.md` and set the TODO's `plan:` field.
   `start` the TODO. (Skippable with "skip plan"/"just do it" for trivial work — the docs
   corpus is still loaded for the doc-sync step.)
3. **Plan review (peer gate)** — complex plans go to a review agent BEFORE implementation:
   1. **Find a live review agent** — don't invent a name glob; use the canonical role
      classifier via `.claude/scripts/agent-fanout.sh status` and pick a live agent whose
      ROLE column is `review`. None alive → ask the user (proceed unreviewed, or wait).
   2. **Send the plan content inline** via `agent-send <reviewer> --stdin` as a
      `PLAN REVIEW REQUEST: <ID> — <title>` asking for: corpus fit, missing applicable
      best-practices rules, scope gaps, simpler alternatives. (Inline — peers see your
      committed repo state only after a merge-down.)
   3. **Wait for the verdict** (read-only review — minutes). Blockers → revise the plan,
      resend until **PLAN GREEN**. Suggestions → adopt or note the rejection in the plan.
      Reviewer goes dark mid-loop: interactively ask the user; under `/afk`, use its
      receipt-watch/failover protocol.
   4. **Record the outcome** in the TODO frontmatter — `plan_review: green (<agent>, <date>)`
      or `plan_review: skipped (<reason>)` (gen-todos-validated). **Implementation does not
      start before a recorded green** (or an explicit user override / recorded skip).
   5. **A material plan revision after green invalidates the record** — re-run the gate or
      append the delta + rationale. Small/trivial plans skip the gate; `--review` /
      `--no-review` override either way.
   6. **User sign-off on the gate's deltas (interactive runs).** After PLAN GREEN, present
      the user what the gate CHANGED — each blocker/suggestion and how the plan moved (or a
      one-line "peer gate: GREEN, no changes") — and get their sign-off before implementation
      starts. The plan side is **user → agent → user**: the user approved the draft, the peer
      hardened it, the user reviews the hardening. **If the Monocle engine is live**
      (`.claude/scripts/monocle-review.sh available`), offer `/monocle-review plan <ID>` for
      this sign-off — there's no diff yet, so the plan IS the subject; the skill sends the
      plan + TODO as artifacts (stable ids) and blocks on the verdict; engine down ⇒ present
      inline as before. **The human is the terminal reviewer of
      every loop** — peer review always precedes and never replaces user review (the diff
      side ends the same way: peer verdict, then the user's go). Under `/afk` this bookend is
      skipped; the delta goes in the journal + final report instead.
4. **Implement** the plan, respecting the cited rules.
5. **Run the gates** (the same gates `/base-test` runs for the touched area) on the working
   tree — no commit yet.
6. **Documentation sync** (before review) — see the doc-sync section below. Ships in the **same
   diff** as the code (still uncommitted).
7. **STOP for USER review — BEFORE any commit** (the human-in-the-loop gate; **`/afk` is the
   only exception**). Present the **uncommitted** change and let the user review it (monocle /
   `git diff` locally). **Never commit until the user has had a chance to review** — this holds
   for EVERY round of changes (the initial implementation AND each later fix round). **If the
   Monocle engine is live** (`.claude/scripts/monocle-review.sh available`), offer
   `/monocle-review diff <ID>` — Monocle reviews the working-tree diff natively and attaches
   the TODO + plan as context (stable ids, update-in-place), then blocks on the verdict; engine
   down ⇒ `git diff` as before.
8. **Commit** referencing the ID — only **after** the user's review in step 7.
9. **Peer review** — send the committed change to a review agent (`/base-pr`, or an `agent-send`
   to a review agent). **Each fix round loops back through step 7 first** (fix on the working
   tree → user review → commit → re-send); repeat until **GREEN**. Peer review precedes — never
   replaces — user review; the human is the terminal reviewer of every loop. (Unchanged by the
   plan-review gate — that gate is additional and earlier.)
10. **Close** — after review + the user's explicit go to ship: run `/todo continue` (promote →
   notify tester → archive). `done`-ing the TODO is the LAST step, after the work ships;
   it ends by **offering `/open-pr <ID>`** when the work should also go up as a GitHub PR.

> Merge-to-base / `/base-push` / tester-notification stay gated on the user's explicit
> approval. Closing the TODO is the final step.

## Doc-sync / doc-drift check (before review)

After implementing + committing, BEFORE stopping for review, reconcile the docs. The edits
ship in the **same diff** as the code. Two responsibilities:

1. **Encode the product/business decisions** this work made into the **product docs**
   (`docs/product.md` for overview, or a topic doc linked from its index). An unencoded
   product decision is itself drift.
2. **Reconcile every doc the change touched.** Each doc is owned by a `define-*` skill and has
   a prescribed shape — additions must match that shape, not be free-form appendages:

| Doc | Owner skill | Shape additions must follow |
|---|---|---|
| `docs/architecture.md` | `define-architect` | New components under `## Components`; new/changed dependencies + data flows; new invariants under `## Invariants`; decisions get a dated entry in `## Decisions log` (newest first). **If you added/removed a component, changed a dependency or data flow, or introduced/changed an invariant, this doc MUST be updated** — an architecture change shipped without it is what review flags. |
| `docs/best-practices.md` | `define-architect` | `scenario + rule + how-to-apply` (match existing sections) |
| `docs/security.md` | `define-deploy` | Rules slot into the matching `## Threat model — <asset>` section (don't append at the end) |
| `docs/testing.md` | `define-qa` | New rules under their category section; cross-cutting (mocking/determinism/coverage) under their headings |
| `docs/api-conventions.md` | `define-architect` | New convention as a section with scenario+rule+how-to-apply; regenerate any API spec (swagger/OpenAPI) if a route/shape changed |
| `docs/product.md` | `define-product` | Product behavior, rules, limits, defaults, edge-cases — the decision must be written down and discoverable |
| `docs/deployment.md` | `define-deploy` | New runbooks under `## Runbooks`; new ops rules in the matching category |
| the relevant `CLAUDE.md` | — | New project rule, env var, port, or convention |

Walk them in priority order: **architecture** and **product** first (the two most commonly
missed and most damaging to leave stale), then best-practices, security, testing, api, deploy.
For each "yes", propose the addition **in the owner skill's shape** and get the user's approval
before writing; commit doc additions reviewably (separate commit, or amend if topical). If
nothing should change, say so explicitly — "nothing to add" is a real outcome confirming the
check happened. If an addition has no precedent in the doc's structure, suggest the user
re-enter the owning `define-*` skill in update mode rather than forcing it.

## Quick reference

| Input | Action |
|-------|--------|
| `/todo add <desc>` (or any substantive work request) | mint `AREA-<NS>-<lane>-NNN`, write file, regenerate |
| `/todo start <ID>` | → in-progress (+ optional plan) |
| `/todo <ID>` / `/todo do the <keyword> todo` | locate + plan + implement → doc-sync → USER review → commit → review |
| `/todo continue` | promote → notify tester → archive (idempotent) |
| `/todo done <ID>` / `cancel <ID>` | close → move to completed/ → offer `/open-pr <ID>` |
| `/todo defer <ID> <milestone>` | change milestone, ID unchanged |
| `/todo block <ID> <blocker>` / `unblock <ID>` | dependency / status |
| `/todo reopen <ID>` | move back from completed/, status open |
| `/todo show <ID>` / `/todo list [filters]` | read-only views |

After every mutating verb: `node .claude/scripts/gen-todos.mjs` + stage the file(s) and `docs/TODO.md`.

## Companion skills

- **`base-push`** — used by `continue` to promote the work into local `<base>` (and publish).
- **`base-pr`** — review pending changes against the base; the reviewer's doc-drift dimension verifies this skill's doc-sync step was done.
- **`base-test`** — what the testing agent runs after `continue`'s notification.
- **`agent-send`** / **`agent-msg`** — dispatch review/test requests and receive replies.
- **`define-product`** — owns `docs/specs/` + `docs/product.md`; a TODO's `spec:` link is auto-loaded into the plan.
- **`define-architect`** — owns `docs/best-practices.md` / `docs/architecture.md` / `docs/api-conventions.md`; doc-sync respects their shapes.
- **`define-qa`** — owns `docs/testing.md`.
- **`define-deploy`** — owns `docs/security.md` + `docs/deployment.md`.
- **`define-tickets`** — shapes the TODO taxonomy (`docs/todos/milestones.json`: areas, priorities, milestones). The TODO files themselves are the tracker — there is no separate `/tickets` skill.

---

**Skill Version**: 1.3.0
**Category**: Workflow, Task Management

## Changelog

- **1.3.0** — **User review before EVERY commit** (human-in-the-loop): the execution
  workflow reorders so the **commit happens only after the user reviews the uncommitted
  change** (monocle / `git diff`) — gates → doc-sync → **USER review → commit → peer review
  → close**. Peer review runs on the user-approved commit; every fix round loops back through
  the user-review gate before its commit. **`/afk` is the sole exception.** Plus **Monocle
  integration**: when the engine is live (`.claude/scripts/monocle-review.sh available`), the
  plan-review sign-off and the user-review-before-commit gate offer `/monocle-review` — the
  diff is reviewed natively while the TODO + plan ride as context artifacts under stable ids
  (update-in-place). Mirrors `feature.md` / `coordinator.md`.
- **1.2.0** — The **lane is now its own dash-delimited segment**: `AREA-<NS>-<lane>-NNN`
  (e.g. `SEC-jn-8-001`), replacing the `<lane>NNN` concatenation that aliased at
  ≥2-digit lanes (an end-unanchored scan for lane 1 matched lane 10's `…-10001`).
  Step 3's scan is now **end-anchored** with a `-?` that spans old+new
  (`^${PREFIX}-${NS}-${LANE}-?[0-9]{3}$`), so a lane never grabs a wider lane's ids
  and the sequence stays continuous. `ID_RE` widened to
  `/^[A-Z]+-([a-z0-9]+-)?(\d+-)?\d{3,}$/`; all prior forms grandfather. Never
  renumber an existing ID.
- **1.1.0** — IDs gain a **per-engineer namespace**: `AREA-<NS>-<lane>NNN` (e.g.
  `SEC-jn-8001`). `<NS>` resolves via `_config.sh`'s `WORKFLOW_TODO_NS` — the
  explicit per-clone knob (recommended; `.claude/workflow.config.local`) → full
  `git user.email` local-part → `0`. The lane stays (per-worktree, intra-engineer);
  NS is the cross-engineer/cross-clone guard so a second engineer's IDs can't
  collide with the fleet's and get lost on merge. `ID_RE` widened to
  `/^[A-Z]+-([a-z0-9]+-)?\d{3,}$/`; legacy bare/lane IDs grandfathered, never
  renumbered. Pairs with the `merge=ours` + post-merge regenerate change so
  `docs/TODO.md` stops conflicting on every merge (`.gitattributes` +
  `regen_merged_artifacts` in the base-* merge paths).
- **1.0.0** — File-per-TODO lifecycle: stable lane-namespaced `AREA-<lane>NNN`
  IDs, frontmatter taxonomy in `milestones.json`, generated `docs/TODO.md` index +
  validator, generator-managed cross-links, the add → plan → implement → doc-sync
  → review → close workflow, and the plan-review peer gate.
