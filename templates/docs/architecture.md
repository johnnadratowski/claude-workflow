# Architecture

System decomposition, data flow, and the invariants that hold across components. `/base-pr` consults this to check whether a PR violates an invariant.

## Components

TODO — list the major components, one paragraph each. What it does, what it depends on, what depends on it.

Example structure:

- **Component A**
  - Purpose
  - Depends on: ...
  - Depended on by: ...
  - Owns: ...

## Data flow

TODO — describe how a request / event / operation flows through the components. A diagram or numbered list works.

## Invariants

Properties that must hold across components. Violating one is a bug, full stop.

Each invariant should be one sentence + a one-paragraph rationale. Example:

> **Invariant:** TODO (one sentence).
> **Why:** TODO (the scenario or design call that makes this invariant necessary).
> **Enforced by:** TODO (a runtime check, a test, a type, a code review rule, etc.).

## Decisions log

Architectural decisions worth remembering, dated. Newest first.

- **YYYY-MM-DD** — TODO: what was decided, what was the alternative, why this won.
