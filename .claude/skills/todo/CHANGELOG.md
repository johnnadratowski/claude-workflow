# todo — changelog

- **7.15.0** — The 3-option prompt's **"Send to Monocle" now explicitly blocks on the
  verdict** (send AND wait, never fire-and-forget) at both the plan gate and the
  implementation/diff gate — choosing Monocle means waiting for the reviewer before
  proceeding. Mirrors `monocle-review` 1.6.0.

- **7.14.0** — Both review gates now present a standardized **3-option prompt**: **1) send
  to Monocle · 2) send to peer review · 3) skip review → implementation/commit**. The plan
  gate (`start` step 3) is restructured around the prompt (peer review is option 2's path);
  step 7 (user review before commit) uses the same three options for the implementation/diff.
  Monocle (option 1) is offered only when its engine is live; **`/afk` does not prompt —
  defaults to peer review**. Mirrors `monocle-review` 1.4.0. (typo note: the "implementation
  review" — not "integration".)

- **7.13.0** — (DX-jn-8-016) **User review BEFORE every commit (human-in-the-loop).** The
  execution workflow reorders so the **commit happens only after the user reviews the
  uncommitted change** (monocle / `git diff`): gates → doc-sync → **USER review → commit →
  peer review → test → close → merge**. Peer review runs on the user-approved commit; every
  fix round loops back through the user-review gate before its commit. Canonical order +
  quick-ref updated. **`/afk` is the sole exception.** Mirrors `feature.md`/`coordinator.md`.
- **7.12.0** — (DX-jn-8-015) **`start` prints TODO + plan links** (new step 5): both a
  docs:dev URL (`WORKFLOW_DOCS_URL`, default `:4000`, per-clone override to the lane port,
  e.g. cc `:4008`) AND a `file://` path (opens in the browser's local Markdown renderer),
  for BOTH the TODO page and its plan. Added `WORKFLOW_DOCS_URL` to workflow.config/_config.sh.
- **7.11.0** — (DX-jn-8-011) **Close-before-MERGE (not just publish), test pre-merge.**
  Extends 7.10.0 from "before publish (origin)" to "before any merge to the base." Split the
  close step into an explicit **Test (pre-merge, on the feature branch)** step then **Close
  (before merge)** — testing no longer requires merging to the base first
  (`/base-test --with-base` tests the combined result without landing the work). Canonical
  order is now **implement → doc-sync → review → test → close → merge**; a TODO is always
  `done` on the feature branch before its work merges to base — never after (that was how
  TODOs hung `in-progress`). `feature.md`/`coordinator.md` + `base-merge`/`base-push` aligned.
- **7.10.0** — (DX-jn-8-009) **Close-before-publish.** Step 9 reordered so `/todo done`
  (archive → `completed/` + `commits:`/`Closes:` + `pnpm gen:todos`) runs on the feature
  branch as part of the SAME diff that then gets merged / `/base-push`ed / `/open-pr`'d —
  so the published base/master/PR carries the closed TODO + regenerated index. Previously
  close was the LAST step (after the push), which lagged the published index (the
  DX-jn-8-007 lesson; `/afk` already closed-then-landed). Note + quick-ref updated to match.
- **7.9.0** — (DX-jn-8-006) The **lane is now its own dash-delimited segment**:
  `AREA-<NS>-<lane>-NNN` (e.g. `SEC-jn-8-001`), replacing the `<lane>NNN`
  concatenation that aliased at ≥2-digit lanes (an end-unanchored scan for lane 1
  matched lane 10's `…-10001`). Step 3's scan is now **end-anchored** with a `-?`
  that spans old+new forms (`^${PREFIX}-${NS}-${LANE}-?[0-9]{3}$`), so a lane never
  grabs a wider lane's ids and the sequence stays continuous across the change.
  `ID_RE` widened to `/^[A-Z]+-([a-z0-9]+-)?(\d+-)?\d{3,}$/`; the prior concatenated
  `AREA-<NS>-<lane>NNN` (`DX-jn-8001`) + bare/legacy forms all grandfather. Never
  renumber an existing ID.
- **7.8.0** — IDs gain a **per-engineer namespace**: `AREA-<NS>-<lane>NNN` (e.g.
  `SEC-jn-8001`). `<NS>` resolves via `_config.sh`'s `WORKFLOW_TODO_NS` — the
  explicit per-clone knob (recommended; `.claude/workflow.config.local`) → full
  `git user.email` local-part → `0`. The lane stays (per-worktree, intra-engineer);
  NS is the cross-engineer/cross-clone guard so a second engineer's IDs can't
  collide with the fleet's and get lost on merge. `ID_RE` widened to
  `/^[A-Z]+-([a-z0-9]+-)?\d{3,}$/`; legacy bare/lane IDs grandfathered, never
  renumbered. Part of DX-8015 (also: `merge=ours` + post-merge regen so
  `docs/TODO.md` stops conflicting on every merge). (DX-8015)

- **7.7.0** — GitHub PR lifecycle hookup: the `done` verb's last step offers
  `/open-pr <ID>` (dedicated frozen `pr/*` branch scoped from the TODO's
  `commits:`), and new optional `pr:` frontmatter (written by `/open-pr`,
  gen:todos-validated) records which PR ships the work. Under `/afk` the
  offer is gated behind its `--pr-on-close` flag. (DX-8011)
- **7.6.0** — Plan-side review ordering is now **user → agent → user**: the
  user approves the draft plan, the peer gate hardens it to PLAN GREEN, and
  the user then signs off on the gate's deltas before implementation (new
  start step 3.6). Stated principle: the human is the terminal reviewer of
  every loop; `/afk` is the autonomous exception (deltas go in its journal +
  final report). (DX-8006)
- **7.5.0** — **Plan-review gate**: complex plans (the ones warranting a
  best-practices section) are peer-reviewed by a review agent BEFORE
  implementation starts — plan sent inline via `agent-send`, revised until
  **PLAN GREEN**, outcome recorded in new `plan_review:` frontmatter
  (`green (<agent>, date)` | `skipped (<reason>)`, gen:todos-validated).
  Reviewer discovery reuses the canonical role classifier
  (`agent-fanout.sh status` ROLE column), not a new name glob. Material plan
  revisions after green invalidate the record. Small-fix plans skip;
  `--review`/`--no-review` override. The step-8 diff review is unchanged.
  Dogfooded on its own plan (DX-8004).
- **7.4.1** — Plans are now **visibly linked** from each TODO: the site layout
  renders all TODO frontmatter (incl. a clickable `plan:` link) as a collapsible
  `.todo-meta` panel above the body, and `todo_plans/` is no longer excluded from
  the Jekyll build (served as plain static `.md`) so the link resolves. Previously
  the `plan:` field was invisible on the rendered page — plans were de-facto
  unlinked. No body duplication: the frontmatter field is the single source.
- **7.4.0** — Plans are now **mandatory on `start`** (every started TODO gets a
  `docs/todo_plans/<slug>.md`, depth scaled to the work, linked via `plan:`) and
  **archived on close**: `done`/`cancel` moves the plan to
  `docs/todo_plans/completed/<slug>.md` and updates the archived TODO's `plan:`
  field so the link survives; `reopen` moves it back. Previously plans were
  optional ("mandatory for complex work") and stayed flat in `docs/todo_plans/`
  with no archival.
- **7.3.0** — Cross-links switched from `.md` to **rendered `.html`** paths
  (`todos/<ID>.html` forward; `../TODO.html` / `../../TODO.html` back). `docs/todos/`
  is now **included** in the Jekyll build with a `layout: default` (a `defaults`
  rule in `docs/_config.yml`), so per-TODO links resolve and render on the docs
  site (`pnpm docs:dev` / Pages). Reverses 7.1.1's local-viewer priority — the
  raw `.md` files no longer self-link in a local markdown viewer / repo browser
  (no `.html` on disk). The site is the priority post docs-nav overhaul; the
  `jekyll-relative-links` plugin is the documented path to serve both surfaces.
- **7.2.0** — IDs are now **lane-namespaced**: `AREA-<lane>NNN` (e.g. `SEC-2001` in
  lane 2), where the lane is this worktree's number from
  `~/.config/goals-worktrees.json` (not found → `0`), and `NNN` is a per-(area, lane)
  sequence. Parallel worktrees mint in disjoint namespaces, so cross-lane ID collisions
  are structurally impossible (replaces the bare per-area counter that produced the
  DX-003 duplicate). Legacy bare `AREA-NNN` IDs are grandfathered — the generator's
  `ID_RE` accepts `\d{3,}`; never renumber an existing ID.
- **7.1.1** — Cross-links are now **relative** `.md` paths (`todos/<ID>.md` /
  `todos/completed/<ID>.md` forward; `../TODO.md` / `../../TODO.md` back) instead
  of absolute GitHub blob URLs, so they resolve in a local markdown viewer and the
  repo browser (clicking opens the sibling file on disk, not a github.com tab).
  The generator picks the back-link depth from each file's location, so a move to
  `completed/` still self-corrects. Trade-off: not served on the Jekyll Pages site
  (`docs/todos/` is excluded) — see the `scripts/gen-todos.mjs` cross-links
  comment.
- **7.1.0** — Generator-managed cross-links: `docs/TODO.md` forward-links every
  ID to its file, and `pnpm gen:todos` injects an idempotent `← Back to the TODO
  index` block at the top of every TODO body. CI `drift-guards` widened to diff
  `docs/todos` so a stale back-link fails the build. Back-links are
  generator-owned — never hand-written.
- **7.0.0** — File-per-TODO model (`docs/todos/<ID>.md` + `completed/` archive),
  stable `AREA-NNN` IDs, frontmatter (status/priority/area/milestone/dates/deps),
  canonical taxonomy in `milestones.json`, generated `docs/TODO.md` index +
  `pnpm gen:todos` generator/validator + CI drift-guard, commit-ID references, and
  the substantive-work→TODO→close workflow. Verbs: add/start/done/cancel/defer/
  block/unblock/reopen/show/list. Replaces the single-`docs/TODO.md` + delete-on-
  complete model.
- **6.0.0** — (prior single-file model: docs-corpus load, doc-drift, stop-for-review,
  `/todo continue`. See git history.)
