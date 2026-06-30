# Todo Skill

## Purpose

The TODO system tracks every substantive unit of work as a **file-per-TODO** with
structured frontmatter (status, priority, area, milestone, dates, dependencies),
a **stable ID** (`AREA-<NS>-<lane>-NNN`), a **generated published index**, and a **completed
archive** (closed TODOs are moved, never deleted). This skill is how you create,
move through, query, and close those TODOs.

**Substantive work runs through a TODO.** When the user asks for a feature, fix,
refactor, or investigation, the flow is: **create the TODO → implement → close it**
(archive + reference the ID in the commit). Trivial edits — typos, one-line tweaks,
formatting — are exempt and committed directly.

## File model (source of truth)

```
docs/todos/
  milestones.json          Canonical taxonomy: milestones→version, areas→prefix, priorities, statuses.
  <ID>.md                  One active/open TODO (status: open | in-progress | blocked | deferred).
  completed/
    README.md              Explains the archive.
    <ID>.md                Closed TODO (status: done | cancelled). MOVED here on close, never deleted.
docs/TODO.md               GENERATED index — never hand-edit. `pnpm gen:todos` rebuilds it; CI drift-guards it.
                           (Each active line carries its `created` date; the rendered Jekyll page adds
                           milestone/area/created/text filters via docs/_layouts/default.html — see DX-2004.)
docs/todo_plans/
  <slug>.md                Per-TODO implementation plan (linked from the TODO's `plan:` field).
                           REQUIRED when a TODO is started — see `start`.
  completed/<slug>.md      Archived plan — MOVED here when its TODO closes (never deleted); the
                           archived TODO's `plan:` field is updated to this path so the link never rots.
```

Each TODO file is frontmatter + body:

```markdown
---
id: SEC-jn-8-001             # AREA-<NS>-<lane>-NNN, stable forever (never changes, even on defer)
title: Short imperative title
status: open                 # open | in-progress | blocked | deferred | done | cancelled
priority: critical           # critical | high | medium | low
area: security               # must match an area in milestones.json; prefix must match the id
milestone: pre-release       # must match a milestone key in milestones.json
created: 2026-05-30           # ISO date, set once
updated: 2026-05-30           # ISO date, bumped on every change
tags: [money-movement]       # free-form labels: compliance, tech-debt, customer-facing, performance, …
blocked_by: []               # [other-ids] — must resolve to real TODOs
plan:                        # set at start: docs/todo_plans/<slug>.md (→ todo_plans/completed/ on close)
plan_review:                 # set by the plan-review gate: "green (<agent>, YYYY-MM-DD)" | "skipped (<reason>)"
                             # validated by gen:todos when present; complex plans must have one before implementation
pr:                          # set by /open-pr: the GitHub PR number that ships this work (validated when present)
# on close, the archived file also carries:
# completed: 2026-05-30
# commits: [<sha>, …]
---

<!-- gen:todos:backlink (managed — do not edit) -->
[← Back to the TODO index](../TODO.md)
<!-- /gen:todos:backlink -->

Body — the full description, scope, links. Preserve detail; this is the record.
```

**Cross-links (forward `todos/<ID>.html` from the index + the generator-injected
`gen:todos:backlink` block above) are generator-managed — never hand-write them.**
`pnpm gen:todos` owns both directions, idempotently; write your body below the backlink
markers. Full `.html`/Jekyll mechanics + the back-link depth rules → [`docs/todo-system-internals.md`](../../../docs/todo-system-internals.md#cross-links-generator-managed).

The **canonical taxonomy** (valid areas/prefixes, priorities, milestones→version,
statuses) lives in `docs/todos/milestones.json`. Read it before assigning fields.
The generator validates every file against it.

## ID allocation

**Format:** `AREA-<NS>-<lane>-NNN` — the area's prefix from `milestones.json` + a
per-engineer namespace `<NS>` + this worktree's lane number + a zero-padded 3-digit
per-(area, NS, lane) sequence (e.g. `SEC-jn-8-001`). IDs are **immutable** — deferring,
blocking, or re-scoping never changes an ID, and legacy forms grandfather; **never
renumber an existing ID**.

**Allocate via the procedure in [`docs/todo-system-internals.md`](../../../docs/todo-system-internals.md#id-allocation)**
(resolve NS → lane → end-anchored scan for the next sequence; the shell snippets +
legacy-grandfathering rules live there).

## Priority

`critical` = money movement / security / data integrity · `high` = correctness,
compliance, auth-adjacent · `medium` = features, DX · `low` = UI visual, copy,
nice-to-haves. **Auto-suggest from area** (money/security → `critical`) but always
confirm with the user.

## After ANY mutation: keep the index live + validate

Every verb that creates/edits/moves a TODO file MUST, before finishing:

1. Run `pnpm gen:todos` — regenerates `docs/TODO.md` AND validates all frontmatter
   (unique IDs, valid enums, prefix↔area match, `blocked_by` resolves, archive
   placement). A non-zero exit means you broke something — fix it.
2. Stage the TODO file(s) **and** the regenerated `docs/TODO.md` together.

CI's `drift-guards` job re-runs the generator + `git diff --exit-code docs/TODO.md`,
so a stale index or invalid frontmatter fails the build.

## Commit-reference convention

A commit that creates, advances, or closes a TODO references its ID:

- In the subject tail: `feat(server): add per-state deposit gate (CMP-001)`, or
- As a trailer: `Refs: CMP-001` (in progress) / `Closes: CMP-001` (on completion).

This is how `git log` ties back to the TODO record. (Not yet a commitlint rule —
convention for now.)

## Verbs

Parse the skill arguments to pick a verb. The lifecycle verbs (`add` → `start` →
`done`) are the spine; the rest are management.

### `add` — create a TODO
Triggers: "add a todo …", or the FIRST step of any substantive work request.
1. Read `docs/todos/milestones.json` for valid areas/priorities/milestones.
2. Decide `area` (→ prefix), `priority` (auto-suggest from area, confirm), `milestone`
   (default `pre-release` for launch-blocking, else ask/infer), `tags`.
3. Mint the next `AREA-<NS>-<lane>-NNN` (resolve NS + lane + scan existing — see ID allocation).
4. Write `docs/todos/<ID>.md` with frontmatter (`status: open`, `created`/`updated` =
   today) + body.
5. `pnpm gen:todos`; report the new ID.

> For a non-trivial change the user just asked you to *do*, `add` is step 1 — mint the
> TODO, then proceed to implement under it, then `done` it. Don't ask "should I make a
> TODO" for substantive work; just do it and tell them the ID.

### `start` — open → in-progress
1. Set `status: in-progress`, bump `updated`.
2. **Write the plan** — `docs/todo_plans/<slug>.md` (slug = lowercased ID + short
   topic, e.g. `srv-8001-db-platform-migration.md`) and set the TODO's `plan:` field.
   **Every started TODO gets a plan** — scale the depth to the work: a complex
   feature gets the full planning-workflow treatment (best-practices section,
   approach, approval before coding); a small fix gets a few lines of scope +
   approach. The plan is what you then work against.
   The `plan:` field is what surfaces the link everywhere: the site layout
   (`docs/_layouts/default.html`) renders all TODO frontmatter — including a
   clickable plan link — as a collapsible `.todo-meta` panel above the body, and
   GitHub renders frontmatter as a table on the raw file. Do NOT duplicate the
   link in the body.
3. **Plan review gate — present the review-path prompt.** When you stop for plan
   review (complex plans — those warranting a "Best-practices rules this work
   touches" section; small-fix plans may skip), ask the user which path, as a
   **3-option prompt**:
   - **1) Send to Monocle** — `/monocle-review plan <ID>` (the user reviews the plan
     in Monocle). **Blocks on the verdict** — send AND wait for it, never fire-and-forget
     (don't start implementing until the reviewer submits). Offer **only when the engine
     is live** (`monocle-review.sh available`); otherwise omit this option.
   - **2) Send to peer review** — a live `review`-role agent hardens it to **PLAN
     GREEN** (the peer-path substeps below).
   - **3) Skip review → implementation** — record `plan_review: skipped (<reason>)`.

   `--review` / `--no-review` force or skip the gate. **Under `/afk` do NOT prompt —
   default to peer review (option 2)**, per the autonomous protocol. Record the chosen
   path's outcome in `plan_review:`; implementation does not start until it's resolved.
   The **peer-review path (option 2)**:
   1. **Find a live review agent** — do NOT invent a name glob; use the
      canonical role classifier via `.claude/scripts/agent-fanout.sh status`
      and pick a live agent whose ROLE column is `review`. None alive → tell
      the user and ask: proceed unreviewed, or wait/start one.
   2. **Send the plan content inline** (peers see your committed repo state
      only after a merge-down, so inline is the reliable form):
      ```bash
      .claude/scripts/agent-send.sh <reviewer> --stdin <<'BODY'
      PLAN REVIEW REQUEST: <ID> — <title>
      Plan doc: docs/todo_plans/<slug>.md (content below). Judge the APPROACH,
      not code: (a) fit with the doc corpus (best-practices, architecture,
      product); (b) best-practices rules cited — any that apply but are
      missing?; (c) scope gaps; (d) simpler alternative? Reply --reply with
      "PLAN GREEN" or numbered findings (blockers vs suggestions).
      <plan content>
      BODY
      ```
   3. **Wait for the verdict** (read-only review — minutes, not a diff audit's
      30–60). Blockers → revise the plan, resend until **PLAN GREEN**.
      Suggestions → adopt or note the rejection in the plan. If the reviewer
      goes dark mid-loop: interactively, ask the user; under `/afk`, use its
      receipt-watch/failover/stop-and-notify protocol.
   4. **Record the outcome** in the TODO frontmatter — `plan_review: green
      (<agent>, <date>)` or `plan_review: skipped (<reason>)` — validated by
      `gen:todos`. **Implementation does not start before a recorded green**
      (or an explicit user override / recorded skip).
   5. **A material plan revision after green invalidates the record** — re-run
      the gate, or append the delta + rationale to the plan doc and note it in
      the `plan_review` value. Don't let the record go stale-but-authoritative.
   6. **User sign-off on the gate's deltas (interactive runs).** After PLAN
      GREEN, present the user what the gate CHANGED — each blocker/suggestion
      and how the plan moved (or a one-line "peer gate: GREEN, no changes") —
      and get their sign-off before implementation starts. The plan side is
      **user → agent → user**: the user approved the draft, the peer hardened
      it, the user reviews the hardening. **If the Monocle engine is live**
      (`.claude/scripts/monocle-review.sh available`), offer `/monocle-review plan
      <ID>` for this sign-off — there's no diff yet, so the plan IS the subject;
      the skill sends the plan + TODO as artifacts (stable ids) and blocks on the
      verdict. Engine down ⇒ present inline as before. Under `/afk` this bookend is
      skipped; the delta goes in the journal + final report instead.
4. `pnpm gen:todos`.
5. **Print the TODO + plan links** so the user can open either, rendered. Source
   `.claude/scripts/_config.sh` for `WORKFLOW_DOCS_URL` (the local docs:dev base —
   default `http://localhost:4000`; per-clone override in `workflow.config.local`
   to the lane's port, e.g. `http://localhost:4008` for the lane-8 cc worktree)
   and resolve the repo root via `git rev-parse --show-toplevel`. Output **both**
   surfaces for **both** the TODO and its plan:
   - **TODO** — docs:dev `${WORKFLOW_DOCS_URL}/todos/<ID>.html` · file `file://<root>/docs/todos/<ID>.md`
   - **Plan** — docs:dev `${WORKFLOW_DOCS_URL}/todo_plans/<slug>.md` · file `file://<root>/docs/todo_plans/<slug>.md`
   The `file://` links open in the browser's local Markdown renderer (no server
   needed); the docs:dev links need `pnpm docs:dev` running on that lane's port.
   (Closed TODOs live at `todos/completed/<ID>.html` + `todo_plans/completed/<slug>.md`.)

### `done` / `cancel` — close a TODO (archive, never delete)
1. Set `status: done` (or `cancelled`), add `completed: <today>` and (for `done`)
   `commits: [<sha>…]`.
2. **Move** the file `docs/todos/<ID>.md` → `docs/todos/completed/<ID>.md` (`git mv`).
3. **Archive the plan too** (when one exists): `git mv docs/todo_plans/<slug>.md
   docs/todo_plans/completed/<slug>.md` and update the archived TODO's `plan:`
   field to the new path — the closed TODO must keep a working link to its plan.
   *Grandfathered case:* a pre-7.4.0 TODO with no `plan:` field skips this step (no
   plan to move) — closing it is fine; don't fabricate a retro plan just to satisfy
   the move.
4. `pnpm gen:todos`; stage the moved file(s) + the regenerated index.
5. The closing commit references the ID (`Closes: <ID>`).
6. **Offer a GitHub PR**: ask the user "open a PR for this work?" → yes invokes
   `/open-pr <ID>` (dedicated frozen `pr/*` branch scoped from this TODO's
   `commits:`; that skill writes the `pr:` back-pointer). Skip the ask when a
   `pr:` already exists or the work is internal-only machinery the user said
   not to publish. Under `/afk`, asked only via its `--pr-on-close` flag.

### `defer <ID> <milestone>` — park for a later milestone
Set **`status: deferred`** AND `milestone` to the new value, bump `updated`, optionally add
a body note explaining why. ID unchanged. `pnpm gen:todos`. (This is what makes the
`deferred` status reachable. To bring it back, `start` it or set `status: open`. A pure
reschedule that stays *active* — not parked — is a hand-edit of just the `milestone` field.)

### `block <ID> <blocker-ID|reason>` / `unblock <ID>`
`block`: set `status: blocked` and add the blocker's **ID** to `blocked_by` (IDs only — a
free-text reason goes in the body, never in `blocked_by`, or the validator rejects it).
`unblock`: **clear the resolved blocker from `blocked_by`** AND set status back to
`open`/`in-progress`. Clearing `blocked_by` is required — the index renders the ⛔ badge
whenever `blocked_by` is non-empty, regardless of status, so flipping status alone leaves a
stale badge. `pnpm gen:todos`.

### `reopen <ID>` — a closed TODO regressed
`git mv` it back from `completed/` to `docs/todos/`, set `status: open`, clear
`completed`/`commits`, add a body note on the regression. If its plan was archived,
`git mv` it back from `docs/todo_plans/completed/` and fix the `plan:` field.
`pnpm gen:todos`.

### `show <ID>` / `list [--milestone X] [--priority Y] [--area Z] [--status S] [--tag T]`
`show`: print the TODO file. `list`: read `docs/todos/` frontmatter, filter, print a
table sorted by milestone → priority. (Or just show the generated `docs/TODO.md`.)

### Editing fields no verb covers
Changing `priority`, `tags`, `plan`, or the body has no dedicated verb — hand-edit the
frontmatter, bump `updated`, then `pnpm gen:todos`. Note `plan:` is **advisory only** — the
generator does not validate the path, so a typo won't be caught; double-check it resolves.

## Planning + execution workflow (for `start`/`done` on non-trivial work)

This preserves the prior skill's review discipline, now hung off the TODO lifecycle.

1. **Load project docs** that inform the work (`docs/server-best-practices.md`,
   `docs/test-best-practices.md`, the relevant `CLAUDE.md`s). Cite the rules the work
   touches. **If the work touches an external API/RPC/provider, also load
   [`docs/integration-notes.md`](../../../docs/integration-notes.md) (C-13)** and verify the
   operations you'll use against the provider's docs (the integration's doc tool first —
   `coinbase-cdp`/`brale` MCPs, `context7`).
2. **Plan** (every started TODO): write `docs/todo_plans/<slug>.md` and set the
   TODO's `plan:` field. For complex work include a "Best-practices rules this work
   touches" section and get approval before coding; for small work a few lines of
   scope + approach suffice. **If the plan touches an integration, add an "Integrations
   touched + contract verification" section** (C-13): which provider + operations, what you
   verified against which doc source + date, and which `integration-notes.md` entries you'll
   add/update in the same diff (money-movement / state-mutating ops are re-verified every time,
   regardless of note age).
3. **Plan review gate** — present the **3-option review-path prompt** (1) Monocle /
   (2) peer review / (3) skip → implementation (see `start` step 3 for the full
   prompt + the peer path). For the peer path: send the plan inline via `agent-send`,
   revise on blockers until **PLAN GREEN**, record the outcome in the TODO's
   `plan_review:` frontmatter, then **present the user the gate's deltas for sign-off**
   (user → agent → user). Small plans skip (`--review`/`--no-review` override either way).
   **The human is the terminal reviewer of every loop** — peer review always
   precedes and never replaces user review; the same shape ends the diff side
   (peer GREEN LIGHT → the user's go to ship). `/afk` is the autonomous
   exception for both loops.
4. **Implement** the plan; `start` the TODO (`in-progress`).
5. **Run the gates** (`types:check`, `eslint`, relevant tests) on the working tree — no commit yet.
6. **Documentation sync** (before review) — per [`docs/doc-sync.md`](../../../docs/doc-sync.md):
   (a) **encode the product/business decisions** this work made into the **product docs**
   (`docs/product.md` for overview, or a topic doc you see fit — e.g.
   `docs/vaults-and-allocations.md` — linked from `product.md`'s index),
   and (b) **reconcile every doc the changed code touched** — best-practices, testing
   (`docs/test-best-practices.md` / `docs/testing.md`),
   `docs/security/*.md`, swagger (`@swagger` JSDoc → `pnpm --filter goals dump:swagger`),
   and the relevant `CLAUDE.md`. In particular, **if the change touched the architecture** —
   added/removed a service or component, changed a data flow, a dependency, the topology, or
   an **invariant** — update [`docs/architecture.md`](../../../docs/architecture.md) (an
   architecture change shipped without the architecture doc reconciled is exactly what
   `/base-pr` flags). The doc edits are part of the **same uncommitted change** as the code.
7. **STOP for USER review — BEFORE any commit** (the human-in-the-loop gate; **`/afk` is the
   only exception**). Present the **uncommitted** change and **prompt the user with the same
   3 options as the plan gate** — now for the implementation/diff:
   - **1) Send to Monocle** — `/monocle-review diff <ID>` (Monocle reviews the working-tree
     diff natively + attaches the TODO/plan as context artifacts, stable ids, then blocks on
     the verdict). Offer **only when the engine is live** (`monocle-review.sh available`).
   - **2) Send to peer review** — `agent-send <reviewer> --stdin` / `/base-pr`.
   - **3) Skip review → commit** — proceed straight to step 8.

   Engine down ⇒ omit option 1 (fall back to `git diff` for option 1's intent). **Under `/afk`
   do NOT prompt — peer review (option 2)**. **Never commit until the user has had a chance to
   review** — this holds for EVERY round of changes: the initial implementation AND each later
   fix round (step 9).
8. **Commit** referencing the ID — only **after** the user's review in step 7.
9. **Peer review** — send the committed change to a review agent (`agent-send <reviewer>
   --stdin`) or run `/base-pr`; address findings. **Each fix round loops back through step 7
   first:** fix on the working tree (uncommitted) → STOP for the user's review → commit →
   re-send. Repeat until peer **GREEN**. Peer review precedes — never replaces — user review;
   the human is the terminal reviewer of every loop (plan and diff). (Unchanged by the
   plan-review gate — that gate is additional and earlier.)
10. **Test — before the merge, on the feature branch.** Once review is GREEN, run the test
   sweep (the testing agent / `/base-test`) **against the feature branch itself —
   testing does NOT require merging to the base first** (`/base-test --with-base` merges the
   base *into* your branch to validate the combined result without landing your work). Fix
   failures the same way — through step 7's user-review gate — re-test until green.
11. **Close — BEFORE you merge.** After review + test pass + the user's explicit go to ship,
   `done` the TODO (archive → `completed/` + `commits:` + `Closes:` + `pnpm gen:todos`)
   **on the feature branch, as part of the SAME diff** you are about to ship — *then*
   merge / `/base-push` / `/open-pr`. **A TODO is ALWAYS closed before its work merges to the
   base — never after.** Closing after the merge is exactly how TODOs hang `in-progress` (and
   lagged the published index — the DX-jn-8-007 lesson). The base / master / PR therefore
   carries the closed TODO and the regenerated index. **Offer `/open-pr <ID>`** (the done
   verb's step 6) when the work should also go up as a GitHub PR.

> The merge-to-base / `/base-push` steps remain gated on the user's explicit approval (see
> the standing review-before-merge rule). The canonical order is **implement → doc-sync →
> USER review → commit → peer review → test → close → merge** — and **no commit ever happens
> until the user has had a chance to review the change that goes into it** (every round, incl.
> fixes). Testing and closing both happen on the feature branch *before* any merge, so
> `done`-ing the TODO is the LAST step **before** the merge — the archive + regenerated index
> ride in the SAME diff that gets merged/pushed/PR'd, so the published state is never stale and
> no TODO is left hanging. **`/afk` is the only exception** to the per-commit user-review gate
> (it runs autonomously on peer review + gates; the user reviews on return).

## Quick reference

| Input | Action |
|-------|--------|
| `/todo add <desc>` (or any substantive work request) | mint `AREA-<NS>-<lane>-NNN`, write file, `gen:todos` |
| `/todo start <ID>` | → in-progress + write plan in `docs/todo_plans/` + set `plan:` + **plan-review gate** for complex plans (peer `PLAN GREEN` → `plan_review:` frontmatter) before implementing |
| `/todo <ID>` / `/todo do the <keyword> todo` | locate + plan + implement (planning workflow) |
| `/todo done <ID>` / `/todo continue` | gates → doc-sync → **USER review → commit** (no commit before user review; `/afk` excepted) → **peer review** (fixes re-gate through user review) → **test** (feature branch, no base merge first) → user go → **archive TODO + plan (close) + regen index** → THEN merge/`/base-push`/`/open-pr` (**close always BEFORE the merge**, same diff) → offer `/open-pr <ID>` |
| `/todo defer <ID> <milestone>` | change milestone, ID unchanged |
| `/todo block <ID> <blocker>` / `unblock <ID>` | dependency / status |
| `/todo reopen <ID>` | move back from completed/, status open |
| `/todo show <ID>` / `/todo list [filters]` | read-only views |

After every mutating verb: `pnpm gen:todos` + stage the file(s) and `docs/TODO.md`.

---

**Skill Version**: 7.15.0
**Category**: Workflow, Task Management

_Version history: see [CHANGELOG.md](./CHANGELOG.md)._
