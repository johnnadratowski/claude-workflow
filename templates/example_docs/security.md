# Security

Threat model + the rules for any code path that handles sensitive data or sensitive operations. `/base-pr` consults this whenever a diff touches an area called out here.

> **⚠ This file ships with EXAMPLE content for a hypothetical web app.** Read it for the format, then delete and replace with your project's real threat model and rules.

## What belongs in this file

- **Threat model** — what's being protected, from whom, and what attacker capability you assume. One section per asset class.
- **Sensitive-operation rules** — scenario + rule + how-to-apply, same shape as `best-practices.md`, scoped to security-relevant code paths.
- **Incident log** — real incidents and near-misses, dated. Each entry should distill a rule into the appropriate section above.

What does NOT belong here: general best practices that aren't security-specific (those go in `best-practices.md`), or library-CVE bulletins (those belong in a CHANGELOG or release notes).

---

# EXAMPLE content

## Threat model

### Asset: user account credentials

- **What we're protecting:** user passwords (never stored plaintext; bcrypt hashes at rest) and session tokens.
- **Threat actors:** (a) unauthenticated network attacker with the ability to read network traffic and submit arbitrary HTTP requests; (b) an authenticated user trying to escalate to another user's account; (c) an insider with read access to the production database backup.
- **Trust boundaries:** HTTPS terminates at the load balancer. Within the cluster, traffic is plaintext but on a private network. Database is on a separate subnet, only reachable from the `api` service.

### Asset: uploaded user content (task attachments)

- **What we're protecting:** files users upload as attachments to their tasks.
- **Threat actors:** (a) an attacker who guesses or enumerates attachment IDs; (b) an attacker who uploads malicious content (script-injection, oversized files, malware) to harm other users or the system.
- **Trust boundaries:** attachments are served from an isolated origin (separate subdomain) with a tight CSP, and behind an authorization check that verifies the requester has access to the parent task.

## Sensitive-operation rules

### Authorization checks happen on the server, not in the client

> **Rule:** Every API endpoint that returns or modifies user data has an authorization check in the route handler. The web client may also do auth-aware UI (e.g., hide a delete button), but that is a UX nicety — the server is the source of truth.
>
> **Why:** Q4 2024 incident: a "delete project" button was hidden in the UI for non-admins but the endpoint had no server-side check. A user discovered they could DELETE any project by replaying the request from a non-admin account. The fix was a server-side `requireRole('admin')` middleware. No UI auth-check is ever load-bearing.
>
> **How to apply:** any new endpoint that touches `database`. The middleware MUST be the first thing the route handler does after `requireAuth`.

### Never log secrets, tokens, or user PII at INFO level

> **Rule:** Anything that could appear in a log aggregation system at INFO level must be safe for an attacker who reads the log to see. That excludes: passwords (even hashed), session tokens, full email addresses, raw user input that contains user-supplied secrets.
>
> **Why:** A debug log line in the password-reset endpoint logged `password_reset_token` at INFO level for two weeks before discovery. The tokens had a 1-hour TTL but the logs persisted 30 days. We had to invalidate all outstanding tokens and notify users.
>
> **How to apply:** when writing a log statement that includes a request body or a database row, scrub the structure for sensitive fields. Maintain an explicit allow-list of fields safe to log; everything else gets `[redacted]`.

### Secrets are loaded at boot from environment, never committed to git

> **Rule:** All secrets (API keys, database passwords, JWT signing keys, etc.) are loaded from environment variables at process startup. The `.env` files are gitignored. CI gets secrets from the platform's secret store, not from `.env` files in the repo.
>
> **Why:** Standard hygiene rule with a familiar failure mode — committed-secret incidents are slow and expensive to clean up (rotate the secret everywhere it's referenced, audit the git history, audit for usage during the exposed window).
>
> **How to apply:** any new secret. Before merging a PR that adds a new env var, also update the project's secret-management runbook so the deploy doesn't break.

## Incident log

- **2024-10-14** — DELETE bypass via missing server-side authz check. Fix: `requireRole('admin')` middleware. Rule distilled into "Authorization checks happen on the server" above.
- **2024-08-02** — password-reset tokens logged at INFO. Fix: redact on log emission. Rule distilled into "Never log secrets" above.
