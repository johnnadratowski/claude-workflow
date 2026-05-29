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

In `update` mode: ask "what do you want to change?" — options include add a new category, change framework, document new convention, regenerate sample tests, restructure docs. Jump in.

## First-run dialog

### Phase A: framework + categories

Open with two questions via `AskUserQuestion`:

> "Do you have a testing framework in mind, or do you want me to suggest one based on the stack?"

> "Which test categories will this project use?"

Multi-select on categories: `unit / integration / E2E / property / fuzz / contract / mutation / benchmark / smoke`.

If the user wants suggestions, propose framework + categories derived from `docs/architecture.md`'s stack table. Justify each. Same critical lens as `define-architect` — challenge the choice. E.g.:

- "You picked Jest for a TypeScript project — Vitest is materially faster for the ESM-native stack you spec'd and has fewer transform-config gotchas. Worth swapping unless you have Jest plugins you depend on."
- "You skipped integration tests — given that this is a service-with-database, that's the category most likely to catch regressions. Are you sure?"

### Phase B: drill loop per category

For each chosen category, run 2-4 questions:

- **Location** — what directory pattern (e.g., `src/**/*.test.ts`, `tests/integration/`).
- **What it covers** — one sentence.
- **What it explicitly does NOT cover** — the boundary with the next category up.
- **Run command** — exact CLI invocation.
- **Prerequisites** — containers, fixtures, ports, env vars. (Important for `/base-test` later.)
- **When to add one** — what code change makes a test in this category mandatory vs nice-to-have.

Write each into `docs/testing.md` as its own section, following the format the existing testing.md template prescribes.

### Drill on cross-cutting concerns

After per-category drills, drill the cross-cutting questions:

- **Mocking policy** — what's OK to mock, what's not. (Common bug source — get the rule written down.)
- **Test data** — fixtures vs factories vs generated, and where they live.
- **Determinism** — how the project handles time, randomness, ordering. Required for property/fuzz tests.
- **Flakiness policy** — what happens when a test is flaky. Quarantine? Delete? Auto-rerun?
- **Coverage targets** — overall, per file, or none. (Pick "none" if "we don't measure it" — don't pretend to have a number you won't enforce.)
- **CI matrix** — what runs in CI vs locally, on what events.

### Challenging unclear answers

Same drilling discipline: "we test everything" → push back. "What does 'everything' mean in observable terms? What's the rule for what gets a test vs what doesn't?" Don't write `we test everything` into the doc.

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
