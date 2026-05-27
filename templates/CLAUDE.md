# <Project name>

<One-paragraph description of what this project is. What it does, who uses it, why it exists. Not the architecture — that's in `docs/architecture.md`.>

This file is intentionally light. The real documentation lives in `docs/`, where it can be specific without bloating the prompt for every Claude session. **When in doubt, read the docs.**

## Must-read

- [`docs/best-practices.md`](docs/best-practices.md) — coding conventions and the scenarios that motivate them. Read before any non-trivial code change.
- [`docs/architecture.md`](docs/architecture.md) — system decomposition, data flow, invariants. Read before changing anything cross-cutting.
- [`docs/security.md`](docs/security.md) — threat model + sensitive-operation rules. Read before touching auth, secrets, or anything that crosses a trust boundary.
- [`docs/testing.md`](docs/testing.md) — where each kind of test lives. Read before adding tests (or claiming a change is tested).
- [`docs/api-conventions.md`](docs/api-conventions.md) — if this project exposes an API, the conventions are here. (Delete this bullet if not applicable.)
- [`docs/TODO.md`](docs/TODO.md) — active backlog. Check before starting work to avoid duplication.

## Hard rules

A small number of rules every contributor should internalize. **Detailed rationale lives in `docs/best-practices.md`** — these are just the headlines.

- TODO: one-line rule (e.g. "Never commit secrets — `.env*` is gitignored; use the `secrets:` make targets").
- TODO: one-line rule.
- TODO: one-line rule.

If a rule below grows past one line of explanation, move it into `docs/best-practices.md` as a scenario + rule + how-to-apply.

## Workflow skills

This repo ships [`claude-workflow`](https://example.com/your-fork-of-claude-workflow) under `.claude/`. Quick reference:

- **`/base-pull`** — merge `origin/<base>` into the current branch.
- **`/base-push`** — push current branch + advance `<base>` locally and on origin.
- **`/base-merge`** — local-only sync (no fetch, no push).
- **`/base-pr`** — review pending changes against `<base>`, optionally promote.
- **`/base-test`** — merge local `<base>`, run every project gate, report.
- **`/agent-send <target> "..."`** — message another Claude session on this machine.
- **`/agent-msg`** — inbound-message handler (invoked automatically).
- **`/agent-rename <name>`** — rename this agent everywhere (registry + tmux + Claude session + git branch).

Configuration lives in `.claude/workflow.config`. Defaults are sensible; override `WORKFLOW_BASE_BRANCH` and `WORKFLOW_MAIN_PATH` per project.

## Common workflows

A few recurring patterns. Detailed steps live with each skill's `SKILL.md`.

- **Starting work on a new branch** → `/base-pull` to get current, then code, then `/base-test` before pushing.
- **Promoting work to the shared branch** → `/base-test` first (sanity), then `/base-push`.
- **Reviewing what's accumulated on the base** → `/base-pr` (optionally splits review and promotion into discrete steps).
- **Asking a peer agent to take on a sub-task** → `/agent-send <name> "..."` and let them reply via `/agent-msg` → `/agent-send --reply`.

## What lives where

- `docs/` — long-form documentation (read these before changing anything covered there).
- `.claude/` — the workflow infrastructure (skills, hooks, scripts). Configuration in `.claude/workflow.config`.
- `<your-source-tree>/` — TODO: name the actual source directories with one-line descriptions.

---

> **For Claude:** before any non-trivial change, read the doc that covers the area you're touching. The pattern is scenario + rule — the scenario explains *why* the rule exists, the rule tells you what to do. If you find yourself fixing a class of bug or applying a non-obvious convention, after the fix is in, propose a scenario+rule for the relevant doc so the next reviewer sees it.
