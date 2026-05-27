# Security

Threat model + the rules for any code path that handles sensitive data or sensitive operations. `/base-pr` consults this whenever a diff touches an area called out here.

## Threat model

TODO — what is being protected, from whom, and what attacker capability we assume. One section per asset.

Example:

### Asset: user credentials

- **What we're protecting:** TODO.
- **Threat actors:** TODO (e.g., unauthenticated network attacker, authenticated user trying to escalate, insider with database read).
- **Trust boundaries:** TODO.

## Sensitive-operation rules

Rules that any code touching a sensitive operation must follow. Scenario + rule + how-to-apply, same shape as `best-practices.md`.

Example sections — replace with your project's actual sensitive operations:

### Authentication

> **Rule:** TODO.
> **Why:** TODO.
> **How to apply:** TODO.

### Authorization checks

> **Rule:** TODO.
> **Why:** TODO.
> **How to apply:** TODO.

### Secret handling

> **Rule:** TODO.
> **Why:** TODO.
> **How to apply:** TODO.

### Logging of sensitive fields

> **Rule:** TODO.
> **Why:** TODO.
> **How to apply:** TODO.

## Incident log

Real security incidents and near-misses, dated. Each entry should distill a rule into the appropriate section above.

- **YYYY-MM-DD** — TODO.
