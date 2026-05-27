# API conventions

If your project exposes an API (HTTP, RPC, library, CLI — anything callers depend on), document its conventions here. `/base-pr` consults this for API-touching diffs.

Delete this file if your project doesn't have an API surface.

## Request/response shape

TODO — describe the canonical shape. Examples.

## Error format

TODO — how errors are represented (status codes, error envelopes, error codes, fields). Examples for common error categories.

## Versioning

TODO — how breaking changes are released. Deprecation timeline.

## Naming

TODO — naming conventions for endpoints, parameters, fields.

## Idempotency

TODO — which operations are idempotent and how callers can rely on that.

## Authentication / authorization

TODO — how callers authenticate. Reference `security.md` for the authorization rules.

## Conventions worth knowing

Scenario + rule + how-to-apply, same shape as elsewhere. These are the API quirks that have caused bugs or confusion in the past.

> **Rule:** TODO.
> **Why:** TODO.
> **How to apply:** TODO.
