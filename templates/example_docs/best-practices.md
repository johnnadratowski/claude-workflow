# Best practices

The conventions of this project, written as **scenario + rule + how-to-apply**. Read this before any non-trivial code change. `/base-pr` consults it during review.

> **⚠ This file ships with EXAMPLE sections to demonstrate the format.** Read them to internalize the shape, then delete and replace with your project's actual rules. The examples are made-up — they don't apply to your code.

## How to read this file

Each section follows the format:

> **Rule** (one imperative sentence).
> **Why:** the scenario that motivated it (one paragraph; cite the bug, the near-miss, or the design call).
> **How to apply:** where the rule kicks in — what code path, what change pattern, what file area.

If a rule has no *why*, it's a draft — finish it or delete it.

## How to grow this file

When a PR fixes a class of bug, or surfaces a convention that wasn't written down, add a new section here. The scenario is the load-bearing part; the rule is just the distillation. Date the section if the scenario is time-sensitive ("Q3 2024 incident — ...").

---

# EXAMPLE SECTIONS — replace with your own

## Function shape: prefer small composable functions over classes

> **Rule:** Default to small testable functions. Reach for a class only when you have ≥ 2 callers that need to share state, OR when the wrapped state has a non-trivial lifecycle (open/close, acquire/release, subscribe/unsubscribe).
>
> **Why:** In Q1 2024 the user-import flow was a `class UserImporter` with 11 instance methods, all called exactly once each, all from the same place. The class wrapper made unit testing each step require constructing the importer with a stub for every dependency — so nobody wrote unit tests, and a regression in the email-normalization step shipped to production. The fix was to inline the methods as plain functions, which restored single-purpose testability.
>
> **How to apply:** when adding a new module, list its public callers before you write the file. If there's exactly one caller and no shared state, write plain functions. If there are multiple callers but no shared state, also plain functions. Only write a class when state must persist across calls AND multiple callers will use it.

## Error handling: never log + return, always log + throw OR return + handle

> **Rule:** When code catches an error, it either re-throws (with optional logging) OR returns a sentinel value the caller is forced to handle by the type system. Never both log and silently swallow.
>
> **Why:** A bug in the order-cancellation worker was invisible for 6 weeks because the dispatcher logged the error and returned `null`, which the caller treated as "no orders to cancel" — a valid case. The log message read "could not cancel order X" but went nowhere noisy enough to be noticed. Errors that get caught and turned into nulls become indistinguishable from "everything's fine, there's just nothing to do."
>
> **How to apply:** when writing a try/catch, ask "if this error fires, does the caller need to do something different?" If yes — throw (re-throw if you log first). If no — don't catch it; let it propagate to the top of the stack and crash loudly. Catching only to log and continue is almost never right.

## Naming: function names are verbs; nouns are for what they return

> **Rule:** Function names start with a verb. If a function's job is "give me X" and the only verb you can think of is `get` or `fetch`, push for something more specific that describes the source or freshness — `loadUserFromCache`, `fetchUserViaHttp`, `resolveUserByEmail`.
>
> **Why:** The codebase had three functions named `getUser` in different files, each with subtly different semantics (one hit the DB, one hit a cache that could be stale up to 5 min, one called an external service). New code routinely picked the wrong one — usually the cheapest-looking one — and we shipped a profile-update bug because the user-profile editor was hitting the 5-min-stale cache and reading back its own write as the old value.
>
> **How to apply:** before naming a function `get*` or `fetch*`, name the *source* in the name. If multiple sources are plausible at the call site, the call site should have to choose between named alternatives, not pick a generic one and pray.

---

# Where to put new sections

Group sections by their **rule shape**, not by file/module they apply to. A "logging" rule that applies to both frontend and backend is one section, not two. If your project ends up with > 30 sections in this file, that's a sign to split — but don't split prematurely; one file is easier to grep.
