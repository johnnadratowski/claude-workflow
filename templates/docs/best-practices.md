# Best practices

The conventions of this project, written as scenarios + rules. Read this before any non-trivial code change. `/base-pr` consults it during review.

## How to read this file

Each section follows the format:

> **Rule** (one imperative sentence).
> **Why:** the scenario that motivated it (one paragraph; cite the bug, the near-miss, or the design call).
> **How to apply:** where the rule kicks in.

If a rule has no *why*, it's a draft — delete it or finish it.

## How to grow this file

When a PR fixes a class of bug, or surfaces a convention that wasn't written down, add a new section here with the scenario + rule + how-to-apply. The scenario is the load-bearing part; the rule is just the distillation.

---

## Example sections — replace with your own

### Function shape

> **Rule:** TODO.
> **Why:** TODO — write the scenario.
> **How to apply:** TODO.

### Error handling

> **Rule:** TODO.
> **Why:** TODO.
> **How to apply:** TODO.

### Logging

> **Rule:** TODO.
> **Why:** TODO.
> **How to apply:** TODO.

### Naming

> **Rule:** TODO.
> **Why:** TODO.
> **How to apply:** TODO.

### State management

> **Rule:** TODO.
> **Why:** TODO.
> **How to apply:** TODO.
