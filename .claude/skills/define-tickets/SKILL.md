---
name: define-tickets
description: Configure the project's work-tracking taxonomy + conventions for the built-in file-per-TODO system. Drills the user on areas (→ ID prefixes), priorities, milestones, the spec↔TODO link, and definition-of-ready/done, then writes them to docs/todos/milestones.json (the canonical taxonomy the /todo skill + gen-todos generator validate against). There is NO external ticketing provider and NO generated /tickets skill — the TODO files under docs/todos/ ARE the tracker.
---

# define-tickets — configure the TODO tracking taxonomy

This project tracks work with the built-in **file-per-TODO** system (`docs/todos/`,
driven by the `/todo` skill + the `.claude/scripts/gen-todos.mjs` generator). There is
**no external ticketing provider** and **no generated `/tickets` skill** — the TODO files
are the tracker. This skill's job is to tailor that system's **taxonomy and conventions**
to the project, by editing `docs/todos/milestones.json` and (optionally) the TODO README.

> Renamed in spirit from the old external-provider integration: if you genuinely need to
> mirror into Jira/Linear/GitHub Issues, that's a separate bespoke integration the user can
> request — it's intentionally out of scope here.

## Modes

- **First run** (taxonomy still has the template defaults): walk the dialog, customize the
  taxonomy to the project's domains + release plan.
- **Re-entry** (taxonomy already customized): "what do you want to change?" — add/rename an
  area, add a milestone, adjust priorities, or revise conventions.

Re-entry detection: read `docs/todos/milestones.json`; if `areas` still matches the shipped
template (feature/bug/security/infra/dx/docs) it's likely a first run.

## Phase A — areas (→ ID prefixes)

Areas partition work and supply the **ID prefix** (`FEAT-`, `BUG-`, …). Ask the user what
the natural buckets are for *this* project. `AskUserQuestion` with the current set plus
suggestions derived from `docs/architecture.md` (e.g. a project with a `server/` and a
`ui/` workspace probably wants `server`/`ui` areas).

For each area, capture `key`, a short `prefix` (uppercase, used in IDs), and a `label`.
Push back on over-splitting (10 areas with 1 TODO each is noise) and under-splitting (one
`misc` bucket defeats the point).

## Phase B — priorities

The template ships critical/high/medium/low. Confirm the **labels** map to this project's
reality (what counts as `critical` here — money movement? data loss? a downed service?).
Keep the four-level scheme unless the user has a strong reason; more levels rarely get used
consistently.

## Phase C — milestones (→ release axis)

Milestones are the release/scheduling axis the index groups by. Default ships
pre-release → initial-release (1.0.0) → post-initial-release → next-minor → backlog. Align
them with the project's actual release plan (from `docs/deployment.md` if it exists):
the version strings, the labels, and whether there's a meaningful "pre-release" gate.

## Phase D — conventions (drill, two-level loop)

Same two-level loop as the other `define-*` skills. Drill the conventions the `/todo` skill
and reviewers will lean on; record them in `docs/todos/README.md` (under a `## Conventions`
section) since they're prose, not taxonomy:

- **★ Definition of Ready** — what makes a TODO pickup-able (clear scope, acceptance criteria,
  linked spec if applicable). Often unwritten; write it.
- **★ Definition of Done** — tied to the doc-sync + review + test gates. When is a TODO
  `done`-able? (reviewed GREEN, tests pass, docs synced, merged.)
- **★ Spec ↔ TODO link** — if the project uses `docs/specs/` (from `/define-product`), how a
  TODO references its spec (the `spec:` frontmatter field) and whether one spec maps to one
  TODO or several.
- **Title convention** — imperative, concise; the first body line is the index "hook".
- **Tag vocabulary** — free-form, or a locked set (e.g. `tech-debt`, `customer-facing`,
  `performance`)?
- **Triage rule** — how `priority` + `milestone` get assigned on `add` (auto-suggest from
  area, confirm with the human).

Areas not covered → record as `## Open questions` in `docs/todos/README.md` for next time.

### Critical-reviewer role

- "We'll figure out priorities as we go" — without a rule, priority is bias. Press for what
  `critical` concretely means here.
- "One area is fine" — a single bucket makes the index useless for filtering. Suggest 3–6.
- "We don't need milestones" — then everything is `backlog`, and the index can't show a
  release picture. Push for at least pre-release vs backlog.

## Phase E — write the taxonomy + validate

1. Write the customized `docs/todos/milestones.json` (areas, priorities, milestones, statuses).
   Keep `statuses` as the canonical set (open/in-progress/blocked/deferred/done/cancelled) —
   the `/todo` skill + generator depend on those exact values.
2. Write the `## Conventions` section to `docs/todos/README.md`.
3. Run `node .claude/scripts/gen-todos.mjs` — it validates the taxonomy and regenerates
   `docs/TODO.md`. A non-zero exit means the taxonomy is malformed; fix it.

## Phase F — critical review

Spawn 2 subagents in parallel:

1. **Taxonomy-fit critic** — read `docs/architecture.md` + `docs/product.md` + the new
   `milestones.json`. List domains/areas the taxonomy misses or over-splits. ~300 words.
2. **Convention-clarity critic** — read `docs/todos/README.md` conventions. List Definition-of-
   Ready/Done gaps, ambiguous triage rules, or missing spec-link guidance. ~300 words.

Present findings, fix, iterate.

## Phase G — signoff

`AskUserQuestion`:
- **Sign off and return to `define-project`** (recommended)
- **One more dialog pass on the conventions** (re-enters Phase D)
- **Adjust the taxonomy** (re-enters Phase A–C)

## What this skill will NOT do

- Integrate an external ticketing provider or generate a `/tickets` skill — the TODO files
  are the tracker.
- Change the canonical `statuses` set (the `/todo` skill + generator depend on it).
- Renumber or rewrite existing TODO IDs when an area's prefix changes — existing IDs are
  immutable; only new TODOs use the new prefix.

## Companion skills

- `define-project` — orchestrator that calls this.
- `define-product` — produces `docs/specs/`; the spec↔TODO link convention lives here.
- `todo` — the runtime tracker this configures; reads `docs/todos/milestones.json` on every verb.
- `define-architect` / `define-deploy` — their `architecture.md` / `deployment.md` inform the
  area + milestone choices.
