---
name: define-qa
description: Interactive testing-strategy definition. Drills with the user on test categories (unit / integration / E2E / property / contract / etc.), framework choice, where tests live, how they're run, and what each category is responsible for. Writes `docs/testing.md` (plus split docs), then seeds the test scaffold — config files, sample tests per category, fixtures dir, test-run scripts. Spawns subagent critics on both docs and scaffold. Owned by `define-project`; runs after `define-architect`.
---

# define-qa — how it's tested

Interactive dialog with the user to define the testing strategy, then seed the test scaffold. Your role: senior QA / SDET who **challenges every untested assumption**.

Produces:

- `docs/testing.md` — categories, locations, run commands, when to add each kind
- `docs/testing/<topic>.md` — split docs (e.g., fixture conventions, mocking policy) when the main file grows
- Test framework config — `vitest.config.ts`, `pytest.ini`, `go test` patterns, etc.
- Sample test files — one per category, demonstrating shape + conventions
- Fixtures / helpers directory layout
- A test-run script / make target / npm script that runs each category

## Re-entry detection

```bash
if [ -f docs/testing.md ] && ! head -1 docs/testing.md | grep -qE '^#\s*Testing\s*$'; then
  mode="update"
else
  mode="first-run"
fi
```

In `update` mode: **start by scanning every `docs/testing*.md` for `## Open questions`** — those bullets are areas the user previously deferred (Phase B's two-level loop records skipped areas there). Surface them first as natural starting points: "Last time you parked these — want to tackle any now?" If none are pending, ask "what do you want to change?" with options: add a new category, change framework, document a new convention, regenerate sample tests, restructure docs, or pick an area from Phase B's list. Jump to the relevant section.

## First-run dialog

### Phase A: framework + categories

Open with two questions via `AskUserQuestion`:

> "Do you have a testing framework in mind, or do you want me to suggest one based on the stack?"

> "Which test categories will this project use?"

Multi-select on categories: `unit / integration / E2E / property / fuzz / contract / mutation / benchmark / smoke`.

If the user wants suggestions, propose framework + categories derived from `docs/architecture.md`'s stack table. Justify each. Same critical lens as `define-architect` — challenge the choice. E.g.:

- "You picked Jest for a TypeScript project — Vitest is materially faster for the ESM-native stack you spec'd and has fewer transform-config gotchas. Worth swapping unless you have Jest plugins you depend on."
- "You skipped integration tests — given that this is a service-with-database, that's the category most likely to catch regressions. Are you sure?"

### Phase B: drill loop — two-level control

Same shape as `define-product` and `define-architect`. The user controls **how deep** to go on each area AND **which areas** to cover.

**Inner loop — depth on a single area.** Pick an area. Drill with `AskUserQuestion` (2–4 questions per turn). Write to `docs/testing.md` (or a split doc). Ask: "Want to go deeper here, or have we covered this enough?" If "deeper", surface the most underspecified follow-up. If "enough", exit.

**Outer loop — area coverage.** Once an area is "enough", surface the next one. Either suggest one (lead with the highest-value missing essential) or present category headings via `AskUserQuestion`. Always offer "I'm done overall" as an option.

**Areas not covered are not failures** — record them as `## Open questions` entries in `docs/testing.md` (one bullet per skipped area, naming the area) so a future `/define-qa` re-entry surfaces them as natural starting points.

Each per-category drill (unit / integration / E2E / etc.) still asks the same six baseline questions inside its inner loop — location, what it covers, what it does NOT cover (boundary), run command, prerequisites, when to add one — and writes them into `docs/testing.md`. The list below adds the cross-cutting areas around them.

### Critical-reviewer role — applies on every answer

Across every area, push back on vague claims:

- "We test everything" → push back. What does "everything" mean *observably*? What's the rule for what gets a test vs what doesn't?
- "It should be reliable" → operationalize. What's the user-visible reliability target?
- "We mock the database" → what specifically? At what boundary? What real-DB tests still exist?
- "We have 80% coverage" → enforced or measured? At what scope? With what gate?

Don't write a vague answer into `docs/testing.md` — drill it down first or record it as an `## Open questions` bullet to revisit.

### The area list

**★** marks the **essentials** — load-bearing for almost any test strategy. **⚙** marks **process-discipline** areas — they look optional but quietly determine whether the testing strategy erodes over time (or holds up).

Areas tagged `(originally covered)` are the only ones the prior version of this skill named; the rest are new.

#### Strategy shape — the pyramid as a decision, not a default

- **★ Pyramid shape** — how much of each category by count *and* by spend (CI minutes). "We test everything" is not a strategy.
- **★ Test ownership** — who fixes a failing test (the author? a QA team? on-call?). Implicit ownership creates orphaned suites.
- **★ Speed budgets per category** — "unit < 10ms p99, integration < 1s p99, E2E < 30s p99" — enforced or aspirational?
- **★ Test isolation contract** — every test starts and ends in a known clean state. What's the contract?
- **★ Parallelization** — can categories / tests-within-category run in parallel? What breaks if they do?
- **Sharding** — split large suites across CI runners
- **Test discoverability** — naming conventions that make tests findable

#### Test categories — per-category drill (each gets its own inner loop)

Categories already named in Phase A: unit / integration / E2E / property / fuzz / contract / mutation / benchmark / smoke. For each chosen one, drill the baseline six questions above. Additional categories to surface in the outer loop:

- **★ Smoke tests** — the X tests that gate a deploy
- **Canary tests / synthetic monitors** — production-running tests
- **Accessibility tests** — axe / pa11y / lighthouse (for UI projects)
- **Visual regression tests** — for UI projects
- **Load / performance / stress** — when scale matters
- **Chaos / fault injection** — when reliability matters
- **Security tests** — SAST / DAST / dep scanning / secret scanning (high-level; deeper threat-model lives in `define-deploy`)
- **Mutation testing** — confidence-in-the-test-suite check
- **API contract / schema-compat tests** — for service projects

#### Data, fixtures, state (extends "test data")

- **★ DB state strategy** — fresh schema vs snapshot-restore vs truncate vs transactions-rolled-back; per-test vs per-suite
- **★ Seed data strategy** — factories (callable builders), fixtures (data files), generators (property-style); pick one as primary (originally covered as "test data")
- **Time freezing** — every test that touches time pins a clock; how is "now" injected so it's mockable?
- **Random seed pinning** — deterministic property / fuzz / random tests
- **⚙ Sensitive data in tests** — rule: never real PII, ever. How is the rule enforced (lint? secret scanner? policy?)
- **External-service stubs** — recorded fixtures (VCR-style), in-process stubs, full mock servers
- **⚙ Test cleanup** — what tests leave behind in shared resources (cache entries, DB rows, S3 objects, message-queue messages)

#### Mocking + integration boundaries (extends "mocking policy")

- **★ Mocking policy** (originally covered) — extended: what's mocked at the unit boundary, what's real in integration
- **★ What's "real" at each level** — DB? Cache? Network? File system? Decision per layer.
- **Contract testing between services** — pact-style, or shared schema?
- **HTTP-client mock pattern** — record/replay vs in-process server vs in-the-test stubs

#### Determinism, flakiness, reruns

- **★ Determinism** (originally covered) — extended checklist: time, random, ordering, shared state, network — each needs a defined handling
- **★ Flakiness policy** (originally covered) — extended: the quarantine workflow, the fix-or-delete SLA, what happens to tests stuck in quarantine for 90 days
- **⚙ Flakiness telemetry** — which tests have flaked most over the last 30 days; who owns each
- **⚙ CI rerun policy** — off / limited / aggressive. Aggressive rerun hides flakiness signal — explicit tradeoff.

#### Coverage + metrics (extends "coverage targets")

- **★ Coverage meta-decision** (originally covered) — enforce or just measure? "We have 80% coverage" is meaningless if nothing breaks at 79%.
- **★ Coverage scope** — total / per-file / per-package / per-changed-line. Different scopes give very different incentives.
- **Critical user journeys (CUJs)** — which are explicitly tested end-to-end vs sampled
- **Suite telemetry** — what's growing, what's slow, what's flaky

#### CI integration (extends "CI matrix")

- **★ Where each runs** — PR / main / nightly / on-demand / pre-release (originally covered as "CI matrix")
- **★ Required vs advisory gates** — which can be overridden, by whom, with what audit trail
- **Test result reporting** — JUnit / Allure / custom — where does it land? Who reads it?
- **Failure mode in CI** — first-failure-stop vs run-to-completion
- **⚙ Quarantine workflow** — failing-test → quarantine → fix-or-delete path (the actual mechanics)

#### Tooling — pick once, use everywhere

- **★ Assertion library** — locked across categories or per-category?
- **★ Mocking library** — same
- **DB test helpers** — transactions-rolled-back vs truncate vs fresh schema
- **Snapshot-test policy** — auto-accept on diff vs manual review

#### Process discipline (the part that erodes silently)

- **⚙ ★ "Every bug fix adds a regression test"** — make this an explicit rule; add it to `docs/best-practices.md` in scenario-rule-how-to-apply format
- **⚙ Exploratory testing sessions** — cadence, who does them, where findings land
- **⚙ Test debt budget** — when a test was skipped/quarantined/disabled, how do we ever come back to it?

#### Specialized (only ask if the project type calls for it)

- **Performance regression** — benchmark + comparison gate
- **Soak testing** — long-running, memory leak detection
- **Profiling in CI** — flamegraphs on PR?
- **Mobile device matrix** — if applicable
- **App-store certification flows** — if applicable
- **Compliance / regulatory testing** — if applicable

#### Quality artifacts beyond tests

- **Test plans per spec** — for big features that need explicit pre-implementation strategy
- **Manual test scripts** — where they live, who maintains
- **Smoke-test runbook** — the steps to manually verify a deploy

### How to surface the list to the user

Don't dump the whole tree at once. When asking "which area next?":

1. If you have a strong recommendation (essentials not yet touched, especially anything load-bearing for what `docs/product.md` says is being shipped), lead with: "I'd suggest <area> next — <one-sentence why>."
2. Show **category headings** as `AskUserQuestion` options plus an "Other" / free-form fallback. Once they pick a category, list bullets *inside* that category for the next selection (or pick the most essential one inside it and ask if they want that or something else).
3. Always offer "I'm done overall" as an option in the outer loop.

## Phase C: subagent critical review of docs

Spawn **3 subagents in parallel**:

1. **Coverage-gap critic** — read `docs/product.md` + `docs/specs/*.md` + `docs/testing.md`. List product behaviors / spec acceptance criteria that no documented test category covers. 400 words.
2. **Boundary critic** — read `docs/testing.md`. List categories with unclear boundaries (a behavior could equally land in two categories) and rules with no failure scenario behind them. 400 words.
3. **Operational critic** — read `docs/testing.md` + `docs/architecture.md`. List operational concerns the testing docs miss: what runs against a real DB, what runs against a stub, how secrets are injected for integration tests, what data the tests leave behind. 400 words.

Consolidate findings, present, decide per-finding, iterate.

## Phase D: test scaffold

Seed the test scaffold matching the chosen framework + categories.

### Typical seeds (adapt to the stack)

#### Node.js / Vitest

- `vitest.config.ts` with project-level config (env, coverage, watchExclude)
- `tests/setup.ts` for shared setup (env loading, global mocks if any)
- `src/<entrypoint>.test.ts` — one sample unit test
- `tests/integration/<sample>.test.ts` if integration is in scope
- `tests/fixtures/` placeholder + a README pointing to fixture conventions
- `package.json` scripts: `test`, `test:unit`, `test:integration`, `test:e2e` matching the categories chosen

#### Python / pytest

- `pyproject.toml` updates for `[tool.pytest.ini_options]`
- `conftest.py` at repo root for shared fixtures
- `tests/test_<module>.py` — one sample unit test
- `tests/integration/test_<sample>.py` if applicable
- `tests/conftest.py` for integration-scoped fixtures
- Makefile / poetry script: `test`, `test-unit`, `test-integration`

#### Go

- `<pkg>/<file>_test.go` — one sample table-driven test
- `internal/testutil/` if shared helpers are warranted
- Makefile targets: `test`, `test-short`, `test-race`

#### Rust

- `tests/` dir for integration tests
- `#[cfg(test)]` module in `src/lib.rs` for unit-test sample
- `Cargo.toml` dev-dependencies for chosen assertion / proptest crates

Adapt as needed. **Ask when unsure.**

### Sample tests, not real ones

The samples demonstrate **shape and conventions**, not real coverage. Use a trivial assertion. The point is "here's where unit tests go, here's how they're written" — actual test writing is downstream work.

### `/base-test` wiring

Update the project's `/base-test` skill or the project root's test-run script so that `/base-test` runs the documented commands. If the `base-test` skill has TODO sections (it ships that way), fill them in now.

### Summary to user

List every file created, grouped by category. Note the test-run commands.

## Phase E: subagent critical review of scaffold

Spawn **3 subagents in parallel**:

1. **Scaffold completeness critic** — does the scaffold cover every documented category? Are samples idiomatic for the framework? 400 words.
2. **Convention-alignment critic** — does the scaffold contradict `docs/testing.md` or `docs/best-practices.md`? 400 words.
3. **Determinism critic** — read the sample tests + setup files. List sources of non-determinism (time, random, ordering, shared state) that aren't guarded. 400 words.

Present, iterate.

## Phase F: signoff

`AskUserQuestion`:

- **Sign off and continue to `define-deploy`** (recommended)
- **One more dialog pass**
- **One more scaffold review pass**

Return control to `define-project`.

## Update mode (re-entry)

Same pattern as the other subskills:

- "What do you want to change?" → route into the relevant phase
- A framework swap regenerates scaffold pieces
- Adding a new category triggers Phase B for that category only + scaffold seed for just that category
- Always end with Phase C/E review + Phase F signoff

## What this skill will NOT do

- Write real tests (only samples that demonstrate shape).
- Cover deployment-pipeline test gates — that's `define-deploy`.
- Cover security-specific testing (auth, fuzzing, penetration testing playbooks) — those go in `define-deploy`'s security section.
- Accept "we test everything" as a rule.

## Companion skills

- `define-project` — orchestrator.
- `define-architect` — provides the stack table that drives framework choice.
- `define-deploy` — next stage; CI-pipeline test gates are configured there.
- `base-test` — the runtime skill that actually runs these tests in dev.
