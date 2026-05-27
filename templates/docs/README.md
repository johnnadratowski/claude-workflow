# Project docs — template

This folder is a starting structure for project documentation that the `claude-workflow` skills can read from and (with explicit instruction) keep up to date. Copy this directory into your project as `docs/` and tailor each file.

## Convention

Each doc is **scenario-and-rule shaped, not topic-and-paragraph shaped**:

- A **scenario** describes a real bug, near-miss, or judgment call from the project's history. One paragraph.
- A **rule** distills the lesson. One sentence, imperative voice ("Use X, not Y, because Z.").
- A **how-to-apply** line tells future readers when the rule kicks in.

This format is intentional. Scenario-shaped docs survive churn — when the project evolves, the *scenario* still explains why the rule existed, even if the code has moved on. Topic-shaped docs (`## Logging`, `## Error handling`) rot the moment the topic-shape changes.

## Files

| File | Purpose | Read by |
|---|---|---|
| `best-practices.md` | Coding conventions and the scenarios that justify them | Every code-touching skill; reviewed by `/base-pr` |
| `architecture.md` | System decomposition, data flow, key invariants | `/base-pr` for "did this PR violate an architecture invariant?" |
| `security.md` | Threat model + sensitive-operation rules | `/base-pr` for security-relevant diffs |
| `testing.md` | Where each kind of test lives and what it covers | `/base-test` for the gate sweep; `/base-pr` for "did this PR add tests where needed?" |
| `api-conventions.md` | If your project exposes an API: request/response shape, error format, versioning | `/base-pr` for API-touching diffs |
| `TODO.md` | Active backlog | All skills as context for "is this in-scope or out-of-scope?" |

## How `claude-workflow` skills use these

- **`/base-pr`** — during review, consults `best-practices.md` to check for rule violations, `architecture.md` for invariant violations, `security.md` for threat-model issues, and `testing.md` to verify test coverage. After review, if the diff changed something covered by a rule, the skill is allowed (with explicit user OK) to update the relevant doc — adding a scenario for the new bug/decision so future reviews see it.
- **`/base-test`** — checks `testing.md` to know which gates correspond to which areas.
- All skills — read `TODO.md` to understand "is this work in scope or already tracked as something else?".

## How to grow these docs

When you fix a class of bug, when you make an architectural decision that locked in a constraint, when a security review caught something — capture the *scenario* (one paragraph, real specifics) and distill the *rule* (one sentence). The scenarios document *why*, the rules document *what*; both are needed.

Don't bloat. A doc that only grows is a doc that gets ignored. Prune scenarios when they're no longer relevant (e.g., the buggy module was deleted). If a rule is now enforced by tooling (a lint rule, a CI check), demote the scenario to a one-line cross-reference.
