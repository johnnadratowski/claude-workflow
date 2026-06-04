# Project docs — example structure

This folder is a starting structure for project documentation. **Every file in here is filled in with real-looking example content** — not TODO placeholders — so you can see exactly what kind of content belongs in each file before you replace it with your own.

To use:

```bash
cp -r path/to/claude-workflow/templates/example_docs path/to/your-project/docs
```

Then walk each file and:

1. Read the example content to internalize the format.
2. Delete the examples.
3. Replace with your project's real content following the same shape.

## The one convention these docs encode

Every doc here is **scenario + rule + how-to-apply** shaped, not topic-and-paragraph shaped:

- A **scenario** describes a real bug, near-miss, or judgment call from the project's history. One short paragraph. Cite specifics — the file, the symptom, the wrong behaviour.
- A **rule** distills the lesson into one imperative sentence ("Use X, not Y, because Z.").
- A **how-to-apply** line tells future readers when the rule kicks in — what code path, what change pattern, what file area.

This format is intentional. Scenario-shaped docs survive churn: when the project evolves, the *scenario* still explains why the rule existed, even if the code has moved on. Topic-shaped docs (`## Logging`, `## Error handling`) rot the moment the topic shape changes.

If you write a rule with no scenario, you've written a draft — finish it or delete it.

## Files in this folder

| File | Purpose | Read by |
|---|---|---|
| `best-practices.md` | Coding conventions and the scenarios that justify them | Every code-touching skill; consulted by `/base-pr` during review |
| `architecture.md` | System decomposition, data flow, key invariants | `/base-pr` for "did this PR violate an architecture invariant?" |
| `security.md` | Threat model + sensitive-operation rules | `/base-pr` for security-relevant diffs |
| `testing.md` | Where each kind of test lives and what it covers | `/base-test` for the gate sweep; `/base-pr` for "did this PR add tests where needed?" |
| `api-conventions.md` | If your project exposes an API: request/response shape, error format, versioning | `/base-pr` for API-touching diffs. **Delete this file if your project has no API surface.** |
| `api.md` | Rendered API reference (Swagger UI over a generated `swagger.json`) | Humans browsing the API. **Delete (with `swagger.json`) if your project has no API** — `/base-initialize` does this on "no API". |
| `todos/` | Work tracking — one file per TODO + `milestones.json` taxonomy; the generated index is `TODO.md` | The `/todo` skill + `gen-todos.mjs`. `docs/TODO.md` is GENERATED — never hand-edit. |

## How `claude-workflow` skills use these

- **`/base-pr`** — during review, consults `best-practices.md` to check for rule violations, `architecture.md` for invariant violations, `security.md` for threat-model issues, and `testing.md` to verify test coverage. After review, if the diff changed something covered by a rule, the skill is allowed (with explicit user OK) to update the relevant doc — adding a scenario for the new bug/decision so future reviews see it. See `base-pr/SKILL.md` step 7.
- **`/base-test`** — checks `testing.md` to know which gate commands correspond to which areas. The actual gate commands belong in the skill or your CI config; `testing.md` documents the *intent* of each category.
- All skills — read `TODO.md` as context for "is this work in scope or already tracked as something else?"

## How to grow these docs

When you fix a class of bug, when you make an architectural decision that locked in a constraint, when a security review caught something — capture the *scenario* (one paragraph, real specifics) and distill the *rule* (one sentence). The scenarios document *why*, the rules document *what*; both are needed.

Don't bloat. A doc that only grows is a doc that gets ignored. Prune scenarios when the buggy module is deleted. If a rule is now enforced by tooling (a lint rule, a CI check), demote the scenario to a one-line cross-reference.
