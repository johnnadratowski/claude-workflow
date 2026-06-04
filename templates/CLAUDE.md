# <Project name>

<One-paragraph description of what this project is. What it does, who uses it, why it exists. Not the architecture — that's in `docs/architecture.md`.>

This file is intentionally light. The real documentation lives in `docs/`, where it can be specific without bloating the prompt for every Claude session. **When in doubt, read the docs.**

## Must-read

- [`docs/best-practices.md`](docs/best-practices.md) — coding conventions and the scenarios that motivate them. Read before any non-trivial code change.
- [`docs/architecture.md`](docs/architecture.md) — system decomposition, data flow, invariants. Read before changing anything cross-cutting.
- [`docs/security.md`](docs/security.md) — threat model + sensitive-operation rules. Read before touching auth, secrets, or anything that crosses a trust boundary.
- [`docs/testing.md`](docs/testing.md) — where each kind of test lives. Read before adding tests (or claiming a change is tested).
- [`docs/api-conventions.md`](docs/api-conventions.md) — if this project exposes an API, the conventions are here. (Delete this bullet if not applicable.)
- [`docs/TODO.md`](docs/TODO.md) — **generated** backlog index (source: `docs/todos/*.md` via the `/todo` skill). Check before starting work to avoid duplication; never hand-edit it.

## Hard rules

A small number of rules every contributor should internalize. **Detailed rationale lives in `docs/best-practices.md`** — these are just the headlines.

- TODO: one-line rule (e.g. "Never commit secrets — `.env*` is gitignored; use the `secrets:` make targets").
- TODO: one-line rule.
- TODO: one-line rule.

If a rule below grows past one line of explanation, move it into `docs/best-practices.md` as a scenario + rule + how-to-apply.

## Workflow skills

This repo ships [`claude-workflow`](https://example.com/your-fork-of-claude-workflow) under `.claude/`. Quick reference:

- **`/base-push`** — land current branch into LOCAL `<base>`, then publish to origin. The only skill that touches origin.
- **`/base-merge`** — local-only sync of `<base>` (down/up; no fetch, no push).
- **`/base-pr`** — local-first review of what's new on `<base>`; optionally promote fixes locally.
- **`/base-test`** — merge local `<base>`, run every project gate, report.
- **`/todo <verb>`** — file-per-TODO lifecycle (add → plan → implement → doc-sync → review → close).
- **`/afk --pr <agent>`** — drive a task to done autonomously (review + test loops).
- **`/agent-send <target> "..."`** — message another Claude session (`--reply` / `--followup`).
- **`/agent-broadcast`** — fan one message out to all live peers (needs explicit authorization).
- **`/agent-msg`** — inbound-message handler (invoked automatically).
- **`/agent-rename <name>`** — rename this agent everywhere (registry + tmux + Claude session + git branch).

Coordination is **local-first**: the local `<base>` ref is shared across worktrees; only `/base-push` touches origin (write-only — no pull skill).

Configuration lives in `.claude/workflow.config`. Defaults are sensible; override `WORKFLOW_BASE_BRANCH` and `WORKFLOW_MAIN_PATH` per project.

## Common workflows

A few recurring patterns. Detailed steps live with each skill's `SKILL.md`.

- **Starting a unit of work** → `/todo add <desc>` (mints the ID), then `/base-merge down` to get current, then code.
- **Promoting work to the shared branch** → `/base-test` first (sanity), then `/base-push`.
- **Reviewing what's accumulated on the base** → `/base-pr` (review + optional local promotion).
- **Asking a peer agent to take on a sub-task** → `/agent-send <name> "..."` and let them reply via `/agent-msg` → `/agent-send --reply`.

## What lives where

- `docs/` — long-form documentation (read these before changing anything covered there).
- `.claude/` — the workflow infrastructure (skills, hooks, scripts). Configuration in `.claude/workflow.config`.
- `<your-source-tree>/` — TODO: name the actual source directories with one-line descriptions.

---

> **For Claude:** before any non-trivial change, read the doc that covers the area you're touching. The pattern is scenario + rule — the scenario explains *why* the rule exists, the rule tells you what to do. If you find yourself fixing a class of bug or applying a non-obvious convention, after the fix is in, propose a scenario+rule for the relevant doc so the next reviewer sees it.
