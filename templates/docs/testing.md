# Testing

Where each kind of test lives and what it covers. `/base-test` runs these; `/base-pr` consults this to check whether a diff added tests where it should have.

## Test categories

TODO — one section per test category in your project. For each:

- **Where it lives:** path pattern (e.g., `**/__tests__/*.test.ts`, `tests/integration/*.py`).
- **What it covers:** one paragraph.
- **What it does NOT cover:** the boundary with the next category.
- **How to run:** the exact command (the same command `/base-test` invokes).

Example structure:

### Unit tests

- **Where:** TODO.
- **Covers:** TODO.
- **Does not cover:** TODO.
- **Run:** TODO.

### Integration tests

- **Where:** TODO.
- **Covers:** TODO.
- **Does not cover:** TODO.
- **Run:** TODO.

### E2E tests

- **Where:** TODO.
- **Covers:** TODO.
- **Does not cover:** TODO.
- **Run:** TODO.

## When to add a test

Rules of thumb for the project. Scenario + rule + how-to-apply.

> **Rule:** TODO (e.g., "Every new public API gets at least one integration test.")
> **Why:** TODO.
> **How to apply:** TODO.

## Test infrastructure

TODO — anything `/base-test` needs to know about your project's test prerequisites (container runtime, fixtures, secrets, ports, etc.).
