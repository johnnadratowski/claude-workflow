# TODO

Active backlog for this project. Used by every skill as "is this work in scope or already tracked?"

> **⚠ This file ships with EXAMPLE todos to demonstrate the format.** Delete them and replace with your project's actual backlog.

## Format

Each todo is a top-level `##` header with a one-paragraph description underneath. Headers prefixed `PROMPT:` are direct instructions for a Claude agent to execute; headers without the prefix are discussion items that require clarification before execution. See the `todo` skill (if your project ships one) for the full convention.

Add new ones at the bottom. Remove (or move to a CHANGELOG if you keep one) when done — don't strikethrough.

If a todo is large enough to need sub-items, use a nested `###` per sub-item.

---

# EXAMPLE todos — replace with your own

## Fix the task-archive button on mobile

The "Archive" button on the task detail page is clipped on viewports under 360px wide. Reproducible on iPhone SE simulator. Investigate whether it's a flex-shrink or a hard-coded width.

Linked: incident-23-mobile-clipped-buttons (Slack #frontend, 2026-05-15).

## PROMPT: Audit error-logging for raw user input

Go through every `logger.error(...)` and `logger.warn(...)` call in `backend/api/` and check whether any log a value that came directly from a request body or query param without scrubbing. Surface a list of findings; if any are clearly logging sensitive fields, propose a one-line fix per location.

Reference: `docs/security.md` — "Never log secrets" rule.

## Refactor: extract the date-formatting helpers into one module

Currently four files have their own `formatDate(d, locale)` — three are identical, one is subtly different (handles a Sunday-vs-Monday week-start case). Pick the right one, extract to `shared/date.ts`, replace all callers, delete the others.

### Sub-task: write a snapshot test against the chosen implementation

Before deleting the duplicates, capture a snapshot of every distinct `formatDate` call site's output for a representative date and locale set. This becomes the regression test for the consolidated implementation.

### Sub-task: update `docs/best-practices.md`

Add a "consolidate before duplicating" rule referencing this refactor.

## PROMPT: Run security review on the new file-upload endpoint

The `/v1/tasks/:task_id/attachments POST` endpoint just landed (PR #423). Walk it against `docs/security.md` — specifically the "uploaded user content" threat model section. Look for: (a) authorization check before upload, (b) content-type validation, (c) size limit enforced before reading the body into memory, (d) ID generation that doesn't allow guessing other users' attachments. Report findings; propose fixes.
