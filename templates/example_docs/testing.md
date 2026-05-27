# Testing

Where each kind of test lives and what it covers. `/base-test` runs these; `/base-pr` consults this to check whether a diff added tests where it should have.

> **⚠ This file ships with EXAMPLE content for a hypothetical multi-tier web app.** Read it for the format, then delete and replace with your project's real test layout and conventions.

## What belongs in this file

- **Test categories** — one section per category. For each: where the tests live (path pattern), what they cover, what they explicitly DO NOT cover (the boundary with the next category), and how to run them.
- **When to add a test** — rules of thumb for when each category is mandatory vs nice-to-have.
- **Test infrastructure** — prerequisites that `/base-test` needs to know about (containers, fixtures, secrets, ports).

What does NOT belong here: details about a single test file's content (that lives next to the test), or test framework setup (that's in the framework's docs).

---

# EXAMPLE content

## Test categories

### Unit tests

- **Where:** colocated with source — `**/*.test.ts` (TypeScript) or `**/__tests__/*.py` (Python). Runs without network, without database, without filesystem (beyond `os.tmpdir`).
- **Covers:** pure functions, single-class behavior, error branches. Anything testable with stubbed-out collaborators.
- **Does not cover:** anything requiring a real DB connection, real HTTP, real file I/O, or real time-dependent behavior. Those are integration.
- **Run:** `pnpm test:unit` (≤ 5 seconds total — if it gets slower, something snuck in that doesn't belong here).

### Integration tests

- **Where:** `tests/integration/**/*.test.ts`. Each test file spins up its own dependencies (containerized DB, in-memory queue) and tears them down.
- **Covers:** real DB queries against a real database, real queue handoff between `api` and `worker`, real auth middleware on real routes.
- **Does not cover:** browser behavior or end-user flows (those are E2E). Doesn't cover the production deployment story (that's in `docs/deployment.md`, not tested).
- **Run:** `pnpm test:integration` (~30s per file in CI; container start dominates).

### E2E tests

- **Where:** `tests/e2e/**/*.spec.ts` (Playwright). Drives the real browser against the local dev stack.
- **Covers:** golden-path user flows — signup, login, create a task, share with another user, archive, delete.
- **Does not cover:** error paths that are too painful to set up. If an integration test can cover it, prefer the integration test.
- **Run:** `pnpm test:e2e` (~3 min in CI; browser launch dominates).

## When to add a test

> **Rule:** Every public API endpoint that touches the database gets at least one integration test exercising the happy path AND one for the authorization-denied case.
>
> **Why:** We had two production bugs in the same quarter where an endpoint shipped without auth check (caught by Q4 2024's DELETE incident — see `security.md`). The integration test for "authz-denied returns 403" makes the check structural — it can't be silently removed without a CI failure.
>
> **How to apply:** every new endpoint. Pattern: `it('returns 403 when caller lacks role X')` adjacent to `it('returns 201 when caller has role X')`.

> **Rule:** Unit tests are mandatory for any non-trivial pure function. Integration tests are mandatory for anything DB- or queue-shaped. E2E tests are mandatory only for new top-level user flows.
>
> **Why:** Forcing E2E for every change makes contributors avoid writing tests at all. Forcing unit tests is cheap. The pyramid is real — most coverage comes from unit + integration; E2E is for "does this whole flow still work."
>
> **How to apply:** when a PR adds code, look at where the new code lives. Module without external deps → unit. Endpoint or worker handler → integration. New user-visible flow → E2E.

## Test infrastructure

- **Containerization:** integration and E2E both need Docker (or a Docker-compatible runtime) running locally and in CI. The runner spins up a fresh DB and queue per test file.
- **Fixtures:** test fixtures live in `tests/fixtures/`. They're seeded into a fresh DB per test file. Do NOT shared-mutate fixtures across tests within a file.
- **Ports:** integration runner binds DB on 5433 (vs prod 5432) and queue on 6380 (vs 6379). If something's already listening on those ports, the runner refuses to start.
- **Secrets:** integration and E2E need a `.env.test` file (gitignored). See `docs/security.md` for the secret-management runbook.

## Gates run by `/base-test`

For each category above, `/base-test`'s gate section (in your project's `.claude/skills/base-test/SKILL.md`) should list:

- `pnpm install --frozen-lockfile` (dependency install)
- `pnpm format:check` (Prettier)
- `pnpm lint` (ESLint)
- `pnpm typecheck` (TypeScript)
- `pnpm test:unit`
- `pnpm test:integration`
- `pnpm build`
- `pnpm test:e2e`

…in that order. Cheap checks first; expensive ones (test:integration, test:e2e, build) last. Replace these with your project's actual commands.
