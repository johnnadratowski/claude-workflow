# API conventions

If your project exposes an API (HTTP, RPC, library, CLI — anything callers depend on), document its conventions here. `/base-pr` consults this for API-touching diffs.

> **⚠ This file ships with EXAMPLE content for a hypothetical REST HTTP API.** Read it for the format, then delete and replace with your project's actual conventions. If your project doesn't expose an API surface, delete this file entirely.

## What belongs in this file

- **Request/response shape** — the canonical structure of a request and a response, with one concrete example.
- **Error format** — how errors are represented (status codes, error envelopes, error codes).
- **Versioning** — how breaking changes are released; deprecation timeline.
- **Idempotency** — which operations are idempotent and how callers rely on it.
- **Naming** — conventions for endpoints, parameters, fields.
- **Authentication / authorization** — how callers authenticate. Reference `security.md` for the rules.
- **Conventions worth knowing** — the API quirks that have caused bugs or confusion. Scenario + rule + how-to-apply.

---

# EXAMPLE: a hypothetical REST API

## Request/response shape

All endpoints accept and return JSON. Requests use standard HTTP verbs:

- `GET /v1/tasks/:id` — fetch one
- `GET /v1/tasks?limit=20&cursor=abc` — paginated list
- `POST /v1/tasks` — create
- `PATCH /v1/tasks/:id` — partial update
- `DELETE /v1/tasks/:id` — delete

Successful responses return the resource directly (no envelope):

```json
{
  "id": "task_01J7XYZ...",
  "title": "Write the docs",
  "status": "open",
  "created_at": "2026-05-27T10:00:00Z"
}
```

List endpoints return `{items, next_cursor}`:

```json
{
  "items": [{...}, {...}],
  "next_cursor": "eyJzZXEiOjQyfQ"
}
```

## Error format

Errors return non-2xx HTTP status + an envelope:

```json
{
  "error": {
    "code": "task_not_found",
    "message": "Task task_01J7XYZ does not exist or you do not have access.",
    "details": null
  }
}
```

- `code` is a stable machine-readable string (snake_case). Callers should switch on this.
- `message` is human-readable; safe to surface to end users.
- `details` is optional, structured, for cases where the caller needs more (e.g., a validation error returns `details: {field: "title", issue: "too long"}`).

**Never include stack traces or internal IDs in `message` or `details`.**

## Versioning

The API is versioned by URL prefix: `/v1/...`. Breaking changes go to `/v2/...`; old versions stay live for at least 12 months after the new one ships, with a deprecation header (`Sunset: <RFC-3339>`) on every response from the deprecated version.

Non-breaking additions (new optional fields, new endpoints, new optional query params) ship to the existing version. Adding a required field to a request, removing a field from a response, or changing the type of a field is breaking.

## Idempotency

- `GET`, `DELETE`, and `PUT` are idempotent — repeating the call has the same effect as one call.
- `POST` creates a new resource each call by default. Callers may pass an `Idempotency-Key` header (UUID); the server caches the response for 24 hours and returns the cached result on a retry with the same key.
- `PATCH` is NOT guaranteed idempotent (depending on the patch operation); callers should pass `Idempotency-Key` if they need it.

## Naming

- Endpoints are plural nouns (`/tasks`, not `/task`).
- Path params are the resource ID (`/tasks/:task_id`, not `/tasks/:id`).
- Query params and JSON fields are `snake_case`.
- Booleans are named for the affirmative (`is_archived: true`, not `not_active: false`).

## Authentication / authorization

Requests authenticate via a session cookie (browser) or `Authorization: Bearer <token>` header (API consumers). See `security.md` for token lifecycle and authorization rules. Endpoints that require special roles declare them at the route level; the runtime middleware enforces. The OpenAPI spec encodes the required role per endpoint.

## Conventions worth knowing

### Cursor-based pagination, never offset

> **Rule:** List endpoints paginate with an opaque cursor. Never with `?page=N&page_size=M`.
>
> **Why:** Offset pagination has the page-skipping bug — when a resource is inserted between requests, the user sees the same resource twice (or skips one). With cursor pagination, the cursor encodes the last-seen sort key, so insertions don't shift the window.
>
> **How to apply:** every new list endpoint. The cursor is base64-encoded JSON of whatever the sort key needs (typically `{seq, id}` for tie-breaking).

### `id` fields are prefixed strings, not UUIDs or integers

> **Rule:** All resource IDs are prefixed strings like `task_01J7XYZ...` (using the ULID format for sortability). Never raw UUIDs, never autoincrement integers.
>
> **Why:** Prefixed IDs make it obvious which resource a string refers to in logs, error messages, and support tickets. Raw UUIDs are unidentifiable at a glance. Integers leak total-count and create enumeration risks.
>
> **How to apply:** every new resource type. The prefix is the resource type name, snake_case.
