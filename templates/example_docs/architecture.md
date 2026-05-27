# Architecture

System decomposition, data flow, and the invariants that must hold across components. `/base-pr` consults this to check whether a PR violates an invariant.

> **⚠ This file ships with EXAMPLE content for a hypothetical "task tracker" web app.** Read it to internalize the format and the kinds of things that belong here, then delete and replace with your project's real architecture.

## What belongs in this file

- **Components** — the major pieces and what each is responsible for. Not exhaustive — only the ones a reviewer needs to know about.
- **Data flow** — how a request or event moves through the components. Diagram or numbered list.
- **Invariants** — properties that must hold across components. Violating one is a bug, full stop.
- **Decisions log** — short notes on architectural decisions, dated. Newest first.

What does NOT belong here: implementation details, library choices that aren't load-bearing, or anything that's already obvious from reading the code.

---

# EXAMPLE: a hypothetical "task tracker" web app

## Components

- **`api`** (`backend/api/`)
  - Stateless Node service handling HTTP requests
  - Depends on: `database`, `worker-queue`, `cache`
  - Depended on by: `web`, external API consumers
  - Owns: request authorization, input validation, audit logging

- **`worker`** (`backend/worker/`)
  - Background job processor (notification emails, daily digests, cleanup tasks)
  - Depends on: `database`, `worker-queue`, external email provider
  - Depended on by: nothing else reads from it — fire-and-forget producer
  - Owns: long-running and async work; idempotency on job retry

- **`database`** (PostgreSQL)
  - System of record for all user-facing data
  - Owns: durability, transactional consistency

- **`worker-queue`** (Redis-backed)
  - Transport for async work between `api` and `worker`
  - Owns: at-least-once delivery semantics (jobs are idempotent at the worker)

- **`web`** (`frontend/web/`)
  - Browser SPA, only talks to `api`
  - Depends on: `api`
  - Owns: all UI state; does not directly talk to the database or queue

- **`cache`** (Redis, separate keyspace from worker-queue)
  - Short-TTL cache for read-heavy endpoints
  - Owns: nothing durable — purely a perf optimization, evictable at any time

## Data flow

A typical "create a task" request:

1. `web` POSTs to `api/v1/tasks`
2. `api` authorizes the user, validates the input, writes to `database` inside a transaction
3. Same transaction: `api` enqueues a `task.created` job onto `worker-queue`
4. `api` returns 201 to `web`
5. `worker` dequeues `task.created`, sends a notification email if needed, retries on transient failure (idempotency key = task ID)

Key property: **the DB write and the queue enqueue happen in the same transaction.** If the queue write fails, the DB rolls back — the system never has a task in the DB with no corresponding job, or vice versa.

## Invariants

> **Invariant:** All durable writes go through `api`. `worker` reads from `database` but never writes to it.
> **Why:** Background jobs that wrote to the DB directly caused two production incidents where audit logging was bypassed (the audit hook lived in `api`). After the second incident, `worker` was refactored to enqueue API calls instead — slower but auditable.
> **Enforced by:** ESLint rule `no-restricted-imports` blocks `worker/` from importing the DB writer module. Code review checks the rule still in place.

> **Invariant:** `web` never holds a long-lived token in localStorage. Auth state is a session cookie (HttpOnly, SameSite=Strict) plus per-render server-injected user metadata.
> **Why:** An XSS-via-third-party-library incident in 2023 exfiltrated tokens from a competitor's app with localStorage-based auth. We moved to cookies after audit.
> **Enforced by:** Code review; integration test that asserts `Application > Local Storage` is empty for sensitive keys after login.

## Decisions log

- **2026-03-12** — Moved background-job dispatch from in-process timers to Redis-backed queue. Trade-off: gained durability across `api` restarts, lost the ability to schedule jobs > 24h out without a separate scheduler (acceptable; we don't have that use case yet).
- **2025-11-04** — Adopted a separate Redis instance for cache vs worker-queue. Cache evictions were causing queue lag during traffic spikes; isolating keyspaces avoided rewriting eviction policy.
