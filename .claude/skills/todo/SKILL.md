---
name: todo
description: Manage `docs/TODO.md` and drive a todo through the full lifecycle — plan (informed by `docs/best-practices.md` and the rest of the doc corpus) → execute → verify → commit → doc-drift check → STOP for review → continue after review → push base branch + notify testing agent → cleanup. Four modes: add, execute (next or by keyword), and continue (post-review).
---

# todo — full-lifecycle todo skill

Drives a todo through every phase: planning (informed by project docs), execution, verification, commit, doc-drift check, then a deliberate stop for human-driven review, then a continuation that pushes the base branch and notifies a testing agent before cleanup.

## File format

`docs/TODO.md` uses markdown headers to define todos. Each `##` header is a todo item, and the content below it (until the next header) is the description. Metadata lines (Status / Plan / Spec / Ticket) immediately under the header are load-bearing — the skill reads and writes them.

```markdown
## Fix the login bug

The login form times out after 30 seconds. Investigate the session handling.

## PROMPT: Review API security

Status: planned
Plan: [docs/todo_plans/review-api-security.md](docs/todo_plans/review-api-security.md)
Spec: 015
Ticket: PROJ-123

Go through all API endpoints and check for authentication issues.
```

- Headers starting with `PROMPT:` are direct instructions for Claude to execute.
- Regular headers are task descriptions that require clarification before execution.
- Metadata lines (each on its own line, immediately after the header, blank line before the description):
  - `Status:` — see state machine below. Absent = untouched.
  - `Plan:` — markdown link to the plan file. Format: `Plan: [docs/todo_plans/<slug>.md](docs/todo_plans/<slug>.md)`.
  - `Spec:` — spec number this todo implements (e.g. `015`). Triggers spec-doc auto-load. Optional.
  - `Ticket:` — provider-specific ticket ID (e.g. `PROJ-123`). Used by Mode 4 + Mode 5 to update the ticket via `/tickets`. Optional.

### Slug derivation

The plan file's slug is **deterministic** from the todo's title so the skill can find it without ambiguity:

```bash
# slug-from-title <title>
slug_from_title() {
  printf '%s' "$1" \
    | sed -E 's/^PROMPT://I; s/^[[:space:]]+|[[:space:]]+$//g' \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9_-]+/-/g; s/-+/-/g; s/^-//; s/-$//' \
    | cut -c1-60 \
    | sed -E 's/-$//'
}
```

Properties: strips `PROMPT:` prefix, lowercases, replaces non-alphanumeric runs with single dashes, collapses dashes, strips leading/trailing dashes, truncates to 60 chars with trailing-dash cleanup. Examples:

| Title | Slug |
|---|---|
| `PROMPT: Add unit tests for auth module` | `add-unit-tests-for-auth-module` |
| `Fix the login bug` | `fix-the-login-bug` |
| `[Spec 015] Implement user signup` | `spec-015-implement-user-signup` |

When this skill writes the `Plan:` link, it uses this slug. When it reads (Mode 4, Mode 5), it re-derives the slug from the todo title to find the file.

### State machine

`Status:` reflects where in the lifecycle the todo is. Used for idempotency (avoid double-pushing, avoid re-running steps after partial failure):

| Status | Meaning | Set by |
|---|---|---|
| (absent) | Untouched. Plan hasn't been created. | — |
| `planned` | `Plan:` link exists. Either awaiting approval or mid-execution. | Mode 1/2 after plan-write |
| `committed` | Code implemented, verified, committed, doc-drift complete. STOP for review reached. | Mode 1/2 after doc-drift |
| `shipping` | Mode 4 in progress. `/base-push` succeeded but cleanup hasn't completed. | Mode 4 between push and cleanup |

`done` is not a state — when Mode 4 cleanup finishes, the whole TODO entry is removed.

The skill **always writes the Status line** when transitioning between phases — Mode 4's idempotency check reads it to decide whether to resume push, notify, or jump straight to cleanup.

## Planning is mandatory (with two narrow exceptions)

**Every TODO item MUST have a plan created before execution, unless:**

- The user explicitly says "skip plan", "no plan", or "just do it"
- The todo is trivially simple (single-line fix, typo, etc.)

### Load project docs BEFORE planning

Before creating any plan, load the project doc corpus. **`docs/best-practices.md` is the primary reference** — every plan must explicitly cite which best-practices rules apply.

```bash
cat docs/best-practices.md docs/architecture.md docs/security.md docs/testing.md \
    docs/api-conventions.md docs/product.md docs/deployment.md docs/tickets.md 2>/dev/null
```

The `2>/dev/null` tolerates missing files — the corpus is whatever the project ships. If a project doesn't have `docs/best-practices.md` yet, the plan should still cite the project's `CLAUDE.md` rules and propose a `docs/best-practices.md` entry as part of the work (via the doc-drift step below).

#### Spec auto-load

If the TODO item has a `Spec:` metadata line (e.g. `Spec: 015`) OR if the title matches a spec (regex `[Ss]pec[\s_-]?0*(\d+)` against `docs/specs/*.md` filenames), **also** load that spec's file:

```bash
spec_num="$(printf '%s' "$TODO_TITLE" | grep -ioE 'spec[ _-]?0*[0-9]+' | grep -oE '[0-9]+' | head -1)"
[ -n "$spec_num" ] && spec_pad="$(printf '%03d' "$spec_num")" && cat docs/specs/${spec_pad}-*.md 2>/dev/null
```

If a spec is loaded, the plan must cite its **Acceptance criteria** by line and the implementation must satisfy them. The commit message also gets a `[Spec NNN]` prefix automatically (e.g. `feat(auth): add session refresh [Spec 015]`).

The plan MUST:

- **Cite the specific best-practices rules** that apply, by section name.
- Cite any architecture invariants the work depends on or could violate.
- Cite security rules if the work touches a sensitive surface.
- **Cite spec acceptance criteria by number** if a spec is linked.
- Respect existing patterns from the docs rather than inventing new ones.

If the plan would violate a documented rule, surface that conflict in the plan — don't quietly bypass.

### Planning workflow

**Note:** For non-PROMPT items, ask clarifying questions BEFORE step 1.

1. **Load docs**: cat the corpus above (plus the spec file if `Spec:` is set or auto-detected).
2. **Propose plan inline**: Call `EnterPlanMode` and propose the plan as the tool input — analysis against the doc corpus, citations, implementation steps. The plan content is the `EnterPlanMode` argument. **Do NOT write any files yet** — plan mode is read-only.
3. **Get user approval**: User reviews the plan and approves via the UI. Approval surfaces as `ExitPlanMode`. If they reject, revise and re-enter plan mode.
4. **Write the plan file** (now that plan mode is exited): save the approved plan to `docs/todo_plans/<slug>.md`, where `<slug>` is computed by `slug_from_title` (see File format above). Include a `## Best-practices rules this work touches` section and (if applicable) a `## Spec acceptance criteria` section. See "Plan file format" below.
5. **Update TODO.md**: add metadata lines under the todo header:
   ```
   Status: planned
   Plan: [docs/todo_plans/<slug>.md](docs/todo_plans/<slug>.md)
   ```
   If a `Spec:` or `Ticket:` line is appropriate (spec auto-detected, ticket inferred from spec link), add those too.
6. **Execute**: implement the approved plan, following the cited rules.
7. **Verify**: ask the user to verify the implementation works correctly. WAIT for confirmation.
8. **Commit**: after user confirms, create a git commit. If a spec is linked, prefix the message with `[Spec NNN]`. Conventional-commits style.
9. **Doc-drift check**: did the implementation introduce something that should be in the docs? Propose additions in each doc's prescribed format (see "Doc-drift check" below); apply approved ones; commit them.
10. **Update Status**: set `Status: committed` in the TODO.md entry.
11. **STOP for review**: print the "Ready for review" summary. If `Ticket:` is set, transition it via `/tickets transition <id> "In Review"` (or the project's review-state name, per `docs/tickets.md`). **Do NOT delete the plan file. Do NOT remove the todo from `docs/TODO.md` yet.** Wait for the user to drive review and then run `/todo continue`.

## Doc-drift check

After every implementation + commit, BEFORE stopping for review, run the doc-drift check. Each doc is owned by a `define-*` skill and has a prescribed shape — additions must match that shape, not be free-form appendages.

| Doc | Owner skill | Shape additions must follow |
|---|---|---|
| `docs/best-practices.md` | `define-architect` | `scenario + rule + how-to-apply` (existing sections show the format) |
| `docs/architecture.md` | `define-architect` | New components under `## Components`; new invariants under `## Invariants`; decisions get a dated entry in `## Decisions log` (newest first) |
| `docs/security.md` | `define-deploy` | Rules slot into the matching `## Threat model — <asset>` section (don't append at the end); same scenario+rule+how-to-apply shape |
| `docs/testing.md` | `define-qa` | New rules under their category's section; mocking / determinism / coverage rules go under their respective cross-cutting headings |
| `docs/api-conventions.md` | `define-architect` | New convention as a section with scenario+rule+how-to-apply |
| `docs/product.md` | `define-product` | Doc-drift here is rare — product changes shouldn't usually come from implementation. If they do, raise it as a concern, not silently add. |
| `docs/deployment.md` | `define-deploy` | New runbooks land under `## Runbooks`; new ops rules in the matching category |
| `docs/tickets.md` | `define-tickets` | Doc-drift here is rare and indicates the convention wasn't documented; raise it. |

Order of priority for the check:

1. **`docs/best-practices.md`** — did this surface a new convention, pattern, or bug-fix class future code should follow?
2. **`docs/architecture.md`** — new component, changed dependency direction, added/strengthened invariant?
3. **`docs/security.md`** — touched a sensitive surface (auth, secrets, user data) in a new way?
4. **`docs/testing.md`** — new test category or infrastructure?
5. **`docs/api-conventions.md`** — added or changed an API convention?
6. **`docs/deployment.md`** — new runbook step, deploy gotcha, or ops rule?

For each "yes", propose a concrete addition **in the shape the owner skill prescribes** (table above). **The user must explicitly approve before writing.** When approved, write the addition and commit it as a separate commit so the doc change is reviewable on its own (or amend the implementation commit if it's topical — user's call). Place additions in the **correct section** of the file (don't blindly append at the bottom — e.g. a security rule slots into the relevant threat-model section).

If a proposed addition would conflict with the doc's structure (e.g. you want to add a new threat-model class to `security.md` but there's no precedent), suggest the user re-enter the owning `define-*` skill in update mode instead of forcing it.

If nothing should be added, say so explicitly in the "Ready for review" summary. Don't silently skip — a "no, nothing to add" is a real outcome that confirms the check happened.

## Stop for review

After the doc-drift check, the skill writes `Status: committed` to the TODO.md entry, then STOPS. It does NOT delete the plan file. It does NOT remove the todo from `docs/TODO.md`.

If `Ticket:` is set on the TODO entry, also transition the ticket via `/tickets transition <ticket-id> "In Review"` (use the project's actual review-state name from `docs/tickets.md` — fall back to `In Review` if undocumented). Surface the transition result. If the transition fails (e.g., illegal state move), surface the error but don't block — the work is done; the ticket can be moved manually.

The stop output should be:

```
✓ Implementation complete and committed (commit <hash>)
✓ Doc-drift check: <added N sections | nothing to add>
✓ TODO.md entry: Status: committed
✓ Ticket: <id> → In Review     [only if Ticket: is set]
   — or —
✓ Ticket: (none linked)

Ready for review.

Next steps:
1. Send to a reviewer for review:
     /agent-send <reviewer-name> "Please review commit <hash> on branch <branch>"

2. Address any review feedback with additional commits.

3. When review is complete, run:
     /todo continue

   That will push your branch up via /base-push (so origin/$WORKFLOW_BASE_BRANCH
   includes your work) and notify a testing agent. After tests come back green,
   the plan file and TODO entry will be cleaned up — and the ticket will be
   transitioned out of In Review (the tester does that, not /todo continue).

To abandon this todo instead of finishing it, run:
     /todo abandon

   That will close the ticket as obsolete and remove the plan + TODO entry.
```

If the user wants to skip the review handoff (e.g., solo work on a low-stakes change), they can run `/todo continue` immediately.

## Modes of operation

### 1. Execute next todo

**Triggers:** "do the next todo", "next todo", "do next", "next task"

Runs the planning workflow on the first unplanned todo. Stops at the review point.

### 2. Search and execute todo

**Triggers:** keyword reference — "do the dead code todo", "do the auth task"

1. Search `docs/TODO.md` for headers matching the keyword (case-insensitive)
2. If one match: run the planning workflow
3. If multiple matches: ask which one
4. If no matches: report and stop

### 3. Add todo

**Triggers:** "add <item>", or anything that doesn't match the other modes

Append a new `## ` header section to `docs/TODO.md`.

### 4. Continue (post-review)

**Triggers:** `/todo continue`, "continue the todo", "finalize the todo", "review is done", "promote"

Assumes the user has driven the review handoff and (if needed) addressed feedback. This mode is **idempotent** — re-running it after a partial failure resumes from the correct step.

#### Idempotency

Before doing anything, read the in-flight todo's `Status:` line and check what already happened:

| Current Status | What's already done | What to run |
|---|---|---|
| `committed` | Nothing past STOP | Full: push → write `Status: shipping` → notify → cleanup |
| `shipping` | `/base-push` succeeded; cleanup didn't finish | Skip push. Check `Notified:` line (see below); skip notify if already sent. Run cleanup. |
| `planned` (no `committed`) | Plan exists but execution wasn't completed | Error — "this todo hasn't reached the review-ready state; run `/todo do <slug>` to finish execution first, or `/todo abandon` to drop it." |
| (no Status) | Nothing started | Error — "no in-flight todo to continue." |
| TODO entry gone but plan file exists | Mode 4 cleanup was partial (TODO removed but plan file left behind) | Delete the plan file, exit cleanly. |
| Both gone | Already finished | Exit cleanly with "already shipped." |

When `/base-push` succeeds in step 1, immediately write `Status: shipping` to the TODO.md entry before doing anything else — that way an interruption between push and notify/cleanup is recoverable.

When the tester is notified, append a `Notified: <tester> @ <iso-timestamp>` metadata line to the TODO entry so re-run can detect it.

#### Steps

1. **Push the base branch** — invoke the `/base-push` skill. Pushes the current feature branch + advances `$WORKFLOW_BASE_BRANCH`. On failure, surface the error and stop — Status stays at `committed`, user fixes and re-runs.
2. **Update Status to `shipping`** — write to the TODO.md entry. Critical for crash-recovery.
3. **Notify the testing agent** — ASK the user for the testing agent's name (or use `WORKFLOW_TESTING_AGENT` from `.claude/workflow.config` if set). Build a notification message that includes the merge SHA and any context derived from the plan ("this changes auth flow; please run integration tests carefully"). Then dispatch:
   ```bash
   "$(git rev-parse --show-toplevel)/.claude/scripts/agent-send.sh" <tester> \
     "Please /base-test on origin/$WORKFLOW_BASE_BRANCH at <merge-sha>. Context: <derived>. Reply with results."
   ```
   Write `Notified: <tester> @ <iso-timestamp>` to the TODO entry on success.
4. **Comment on the ticket** if `Ticket:` is set:
   ```
   /tickets comment <ticket-id> "Sent to <tester> for /base-test on <merge-sha>"
   ```
   (Don't transition the ticket here — the tester will do that when they confirm. Just leaving a comment so the ticket's audit trail records the handoff.)
5. **Cleanup (only AFTER push + notify + ticket-comment all completed):** delete the plan file from `docs/todo_plans/<slug>.md` AND remove the todo's section from `docs/TODO.md`. Commit the cleanup as `chore(todo): finalize <todo title>`. Local-only; ships with the next push.
6. **Report** — confirm push, tester notification, ticket comment, and cleanup. Testing is asynchronous; the tester will reply via `/agent-msg` when done and will transition the ticket to Done themselves.

If the user opted out with "skip notify" / "no tester", steps 3-4 are omitted but cleanup in step 5 STILL runs after the push (the work is shipped; just unattended testing).

### 5. Abandon

**Triggers:** `/todo abandon`, "abandon this todo", "drop this todo", "cancel this todo"

Stops tracking an in-flight todo without finishing it. Closes the linked ticket (if any) as obsolete, deletes the plan file, removes the TODO entry. **Does NOT revert any code that was committed** — that's a separate concern (use `git revert` or a follow-up todo).

1. **Identify the in-flight todo** — look in `docs/todo_plans/` for plan files (same resolution as Mode 4). If multiple, ask. If none, error.
2. **Read the plan** to recover the todo title (for the commit message + ticket close reason).
3. **Confirm with the user** — `AskUserQuestion` showing the title + current Status + linked ticket (if any) + a "Yes, abandon it" / "No, cancel" option pair. Default to cancel. **Always confirm — abandonment is not silently reversible.**
4. **Warn about uncommitted work** — if `git status` shows uncommitted changes related to this todo, surface them and ask whether to commit them, discard them, or leave them dirty. Default: leave them; abandonment doesn't touch the working tree by default.
5. **Warn about pushed work** — if `Status: shipping` (push already happened), explain that origin/$WORKFLOW_BASE_BRANCH still contains the work; abandonment only removes the local tracking markers. If the user wants to actually undo the merge, that's a separate manual revert.
6. **Close the ticket** if `Ticket:` is set:
   ```
   /tickets close <ticket-id> "Abandoned: <user-supplied reason>"
   ```
   Ask the user for a one-sentence reason. Default reason is "abandoned via /todo abandon".
7. **Delete the plan file** — `rm docs/todo_plans/<slug>.md`.
8. **Remove the TODO entry** — strip the entire section from `docs/TODO.md`.
9. **Commit** — `chore(todo): abandon "<title>"` with the reason in the body. Local; ships with the next push.
10. **Report** — confirm ticket closed (or "no ticket linked"), plan deleted, TODO entry removed, and surface any open warnings (uncommitted work, pushed-but-not-reverted code).

## How to determine mode

Parse the arguments:

1. **Continue (post-review)**: phrases like "continue", "finalize", "review done", "review is done", "promote".
2. **Abandon**: phrases like "abandon", "drop this", "cancel this todo".
3. **Execute next**: "do the next todo", "next todo", "do next", "next task", "do the next one".
4. **Search and execute**: "do the <keyword> todo/task".
5. **Add todo**: everything else.

If `/todo do <keyword>` matches a todo whose `Status:` is `committed` or `shipping`, surface that and ask whether the user wants to resume work on it (re-enter execution) or pick a different todo. **Don't silently re-execute** a todo that's mid-lifecycle.

## Implementation: Execute next todo

1. **Read `docs/TODO.md`**: get current contents.
2. **Find first unfinished header**: parse `## ` headers in order. Pick the first one whose `Status:` is absent or `planned`. **Skip** any with Status `committed` or `shipping` (those are mid-lifecycle — surface them in the report but don't auto-resume).
3. **Read metadata**: parse `Status:` / `Plan:` / `Spec:` / `Ticket:` lines.
4. **If no plan exists** (no `Plan:` link, Status absent):
   a. Auto-detect a spec link if the title matches `[Ss]pec[\s_-]?0*\d+`.
   b. Load docs corpus + spec file (if linked) per the "Load project docs" section above.
   c. For non-PROMPT items: ask clarifying questions first.
   d. Call `EnterPlanMode` with the proposed plan inline — analysis, rule citations, spec acceptance-criteria mapping (if applicable), implementation steps. Do NOT write files yet.
   e. Wait for user approval (`ExitPlanMode`). On rejection, revise and re-enter.
   f. After approval: write plan to `docs/todo_plans/<slug>.md` (slug from `slug_from_title`), update `docs/TODO.md` with `Status: planned` + `Plan:` link + (if applicable) `Spec:` + `Ticket:`.
5. **If plan exists** (Status `planned`): re-read the plan file. Skip back to execution.
6. **Execute**: follow the approved plan, respecting cited rules.
7. **Verify**: ask the user to verify the implementation works. WAIT for confirmation.
8. **Commit**: after verification, create a git commit (conventional-commits style). Prefix message with `[Spec NNN]` if a spec is linked.
9. **Doc-drift check**: for each doc in the corpus, ask if this implementation introduced something that should be added. **Prioritize `docs/best-practices.md`.** Propose additions in the shape the owning `define-*` skill prescribes (see "Doc-drift check" above). WAIT for user approval. Apply approved additions + commit each as its own commit.
10. **Update Status**: write `Status: committed` to the TODO.md entry.
11. **STOP for review**: if `Ticket:` is set, run `/tickets transition <id> "In Review"` and surface the result. Print the summary (see "Stop for review" above). **Do NOT delete the plan file. Do NOT remove the todo from `docs/TODO.md`.**

## Implementation: Search and execute todo

Same as Execute Next, but the search comes first:

1. **Extract keyword** from arguments.
2. **Read `docs/TODO.md`**.
3. **Search**: Find headers containing the keyword (case-insensitive).
4. **Handle results**:
   - One match → proceed with the planning workflow.
   - Multiple matches → ask the user which one.
   - No matches → report and stop.

Then steps 4–10 from Execute Next above.

## Implementation: Continue (post-review)

1. **Identify the in-flight todo and its state** — scan `docs/TODO.md` for the entry whose `Status:` is `committed` or `shipping`.
   - Exactly one match → use it. Cross-check `docs/todo_plans/<slug>.md` exists.
   - Multiple → ask the user which slug.
   - None with `committed`/`shipping` Status, but a plan file exists → check the orphan path (plan file without TODO entry); clean up the orphan.
   - Nothing → error: "No in-flight todo to continue."
2. **Read the plan file** to recover the todo title, the spec (if any), and any plan-derived context for the tester notification.
3. **Idempotency branch** — apply the rules in the Mode 4 table:
   - `committed` → push, then continue
   - `shipping` → skip push (already done); check `Notified:` and skip notify if present.
4. **Push the base branch** (if not already done): invoke `/base-push`. On success, immediately write `Status: shipping` to the TODO entry. On failure, surface the error and STOP — Status stays at `committed`; user fixes and re-runs `/todo continue`.
5. **Notify the testing agent** (if not already done): ask for the agent name (or read `WORKFLOW_TESTING_AGENT`). Build a context line from the plan (e.g. "this changes auth flow; please run integration tests carefully"). Then run:
   ```bash
   "$(git rev-parse --show-toplevel)/.claude/scripts/agent-send.sh" <tester> \
     "Please /base-test the latest origin/$WORKFLOW_BASE_BRANCH (merge commit <hash>) — work from todo '<title>'. <context-line>. Reply with results."
   ```
   On success, write `Notified: <tester> @ <iso-timestamp>` to the TODO entry. If "skip notify" / "no tester", omit but still continue to ticket-comment + cleanup.
6. **Comment on the ticket** if `Ticket:` is set (and the comment wasn't already left — check the ticket's recent comments via `/tickets get <id>` if you want to be defensive, otherwise just attempt and tolerate "already commented" as no-op):
   ```
   /tickets comment <ticket-id> "Sent to <tester> for /base-test on <merge-sha>"
   ```
7. **Cleanup** — ONLY after push + notify + ticket-comment have all completed (or been intentionally skipped):
   a. Delete the plan file: `rm docs/todo_plans/<slug>.md`.
   b. Remove the todo's section from `docs/TODO.md` (including all metadata lines).
   c. Commit the cleanup with message `chore(todo): finalize <todo title>`. Local-only; ships with the next push.
8. **Report**: confirm push (or "already pushed"), tester notification (or "already notified" / "skipped"), ticket comment (or "no ticket linked"), cleanup. Note testing is async — the tester replies via `/agent-msg` when done and transitions the ticket themselves.

## Implementation: Abandon

1. **Identify the in-flight todo** — same resolution as Continue (look for a `Status:`-bearing entry). If multiple, ask. If none, error.
2. **Read the plan** to recover the title + spec + ticket.
3. **Confirm via `AskUserQuestion`** — display the title, current Status, linked ticket. Options: "Yes, abandon it" / "No, cancel" (default cancel).
4. **Ask for a reason** — one sentence. Used in the ticket close and the commit message body. Default: "abandoned via /todo abandon".
5. **Check working tree** — `git status`. If there are uncommitted changes that look related (heuristic: any file mentioned in the plan), surface them and ask: commit / discard / leave-dirty. Default leave-dirty.
6. **Check shipping state** — if `Status: shipping`, warn that origin/`<base>` still contains the work; abandonment only removes tracking markers. If the user wants an actual revert, they do it manually (suggest `git revert <merge-sha>` + `/base-push`).
7. **Close the ticket** if `Ticket:` is set:
   ```
   /tickets close <ticket-id> "Abandoned: <reason>"
   ```
   On failure (e.g., illegal state transition), surface the error but don't block — finish the local cleanup; ticket can be closed manually.
8. **Delete the plan file** — `rm docs/todo_plans/<slug>.md`.
9. **Remove the TODO entry** — strip the entire section (header + metadata + description).
10. **Commit** — `chore(todo): abandon "<title>"`. Body includes the reason.
11. **Report** — confirm: ticket closed (or "no ticket linked"), plan deleted, TODO entry removed. Surface any warnings (uncommitted-but-related work, pushed-but-not-reverted code).

## Implementation: Add todo

1. **Parse arguments**: Use the provided text as the todo title.
2. **Read `docs/TODO.md`**: Get current contents.
3. **Format**: Create a new `## ` header section.
4. **Append**: Add to end of file.
5. **Confirm**: Tell the user what was added.

## Skipping planning

Users can skip planning by including:

- "skip plan"
- "no plan"
- "just do it"
- "without planning"

Skipping planning skips `EnterPlanMode` + the plan-file write + the `Plan:` link. **The docs corpus is still loaded** — the doc-drift check (which still runs) needs it, and the executor still respects documented rules even without a written plan. After execution, the Status line still gets set to `committed` and Stop-for-review still happens; the only missing artifact is the plan file. A subsequent `/todo continue` works the same way (it doesn't require a plan file — only the TODO entry's `Status:` line — but if missing, falls back to a synthesized title from the TODO header).

## Skipping doc-drift

Users can skip the doc-drift check with:

- "skip doc-drift"
- "no doc-drift"
- "don't check docs"

The skill still stops for review.

## Plan file format

```markdown
# Plan: <Todo Title>

## Summary

Brief description of what this plan accomplishes.

## Linked artifacts

- Spec: <NNN-slug.md> — (if applicable; auto-detected from title or Spec: line)
- Ticket: <PROJ-123> — (if applicable; from Ticket: line)

## Best-practices rules this work touches

- `docs/best-practices.md` → "<Rule name>": <one-sentence relevance>
- `docs/best-practices.md` → "<Rule name>": <one-sentence relevance>
- `docs/architecture.md` → "<Invariant>": <one-sentence relevance>

(If no rules apply: state that explicitly with "No documented rules apply to this work — flagging this for the doc-drift step.")

## Spec acceptance criteria

(If a spec is linked) — list each acceptance criterion from the spec by number, and map to the implementation step that satisfies it.

- Spec NNN AC #1 → Step 2
- Spec NNN AC #2 → Step 4
- ...

## Analysis

- Key findings from codebase exploration
- Dependencies identified
- Potential challenges

## Implementation Steps

### Step 1: <Description>

- Details of what to do
- Files to modify
- Code patterns to follow (cite docs if applicable)

### Step 2: <Description>

...

## Files to Modify

- `path/to/file1.ts` — Description of changes
- `path/to/file2.ts` — Description of changes

## Testing Strategy

How to verify the implementation works. Reference `docs/testing.md` for which test categories apply.

## Risks and Mitigations

Any potential issues and how to handle them.
```

## Verification and commit

After implementing any todo, you MUST:

1. **Ask for verification**: Prompt the user to verify the implementation works correctly.
2. **Wait for confirmation**: Do NOT proceed until the user explicitly confirms.
3. **Commit the changes**: After user confirmation, create a git commit (conventional commits).
4. **Proceed to doc-drift**: Only after commit succeeds.

**Never skip the verification step.** Never assume the implementation is correct without user confirmation.

## Cleanup after completion

**Cleanup happens in Mode 4 (Continue) or Mode 5 (Abandon), not at the end of Mode 1/2.** The plan file and TODO entry persist through the review phase so that:

- The reviewer (a peer agent, or the user themselves later) can read the plan to understand intent.
- Re-running the skill in the middle of review doesn't lose state.
- The `Status:` line on the TODO entry surfaces the lifecycle state to anyone reading `docs/TODO.md` (or to a `/todo` re-run, which uses it for idempotency).

When Mode 4 runs, cleanup is the LAST step — AFTER the push, tester notification, and ticket comment — so the TODO entry tracks the work's true state: it stays in the list until the work is shipped AND the tester has been notified. The cleanup commit is local; ships with the next push.

When Mode 5 (Abandon) runs, cleanup happens AFTER the ticket close (so a re-run after partial failure detects the ticket is already closed). Mode 5 doesn't push anything — the abandonment only affects the local tracking markers + the ticket.

## PROMPT prefix convention

Headers prefixed with `PROMPT:` are **direct instructions** for Claude to execute:

- `## PROMPT: Review all API endpoints` → proceed directly to docs-load and planning.
- Strip the `PROMPT:` prefix; the remaining text plus section content is the instruction.

Headers **without** `PROMPT:` are **discussion items**:

- `## Fix the login bug` → ask clarifying questions before docs-load and planning.

### Workflow difference

**PROMPT items:**

1. Parse the instruction.
2. Load docs corpus.
3. Proceed directly to planning.

**Non-PROMPT items:**

1. Read and understand the todo.
2. **Ask clarifying questions** about scope, approach, priorities, edge cases.
3. After user confirms direction, load docs corpus.
4. Then proceed to planning.

## File locations

Paths are relative to the repo root. **`docs/todo_plans/` is per-worktree state** (lives in the working tree, not in `.git/`), so concurrent in-flight todos in sibling worktrees don't collide — each worktree has its own plans dir.

- TODO file: `docs/TODO.md`
- Plans directory: `docs/todo_plans/`
- Best-practices: `docs/best-practices.md` (primary reference for plans and doc-drift; owned by `define-architect`)
- Architecture: `docs/architecture.md` (owned by `define-architect`)
- Security: `docs/security.md` (owned by `define-deploy`)
- Testing: `docs/testing.md` (owned by `define-qa`)
- API conventions: `docs/api-conventions.md` (owned by `define-architect`)
- Product: `docs/product.md` (owned by `define-product`)
- Deployment: `docs/deployment.md` (owned by `define-deploy`)
- Tickets conventions: `docs/tickets.md` (owned by `define-tickets`)
- Specs: `docs/specs/NNN-*.md` (owned by `define-product`; auto-loaded if a TODO entry's `Spec:` line or title references one)

If your project uses different file names, customize the docs-load `cat` line accordingly.

## Example interactions

### Execute next todo (with planning + docs + doc-drift)

```
User: /todo do the next todo

Claude: Found todo: "PROMPT: Add unit tests for auth module"

Loading project docs corpus...
  ✓ docs/best-practices.md (3 rules potentially apply)
  ✓ docs/testing.md (unit test conventions)
  ✓ docs/security.md (auth-related rules)

Creating implementation plan...

[Enters plan mode, analyzes against docs, creates plan citing applicable rules]

Claude: Plan saved to docs/todo_plans/add-unit-tests-for-auth-module.md.

Rules this work touches:
- best-practices.md → "Function shape: prefer small composable functions"
- testing.md → "Unit tests are mandatory for any non-trivial pure function"
- security.md → "Authorization checks happen on the server, not in the client"

Please review the plan and approve to proceed.

[User approves]

Claude: Executing plan...
[Executes]

Claude: Implementation complete. Please verify, then I'll commit and run the doc-drift check.

[User verifies]

Claude: Creating commit...
[Creates git commit]

Claude: Doc-drift check:
  - best-practices.md: ✓ no new patterns introduced
  - architecture.md: ✓ no invariant changes
  - security.md: I noticed the new tests exercise token-refresh edge
                cases that aren't documented. Propose adding to
                docs/security.md:

                > Rule: Token-refresh paths require explicit tests for
                > each of: (a) refresh during a valid session, (b)
                > refresh after expiration, (c) refresh with a revoked
                > token. Why: ...
                > How to apply: ...

  Apply this addition?

[User approves]

Claude: Wrote the addition to docs/security.md, committed as a separate commit.

✓ Implementation complete and committed (commit a1b2c3d)
✓ Doc-drift check: 1 section added to docs/security.md

Ready for review.

Next steps:
1. Send to a reviewer:
     /agent-send <reviewer-name> "Please review commits a1b2c3d..e4f5g6h on auth-tests"

2. Address any review feedback.

3. When review is complete, run:
     /todo continue

   That will push to $WORKFLOW_BASE_BRANCH via /base-push and notify a testing agent.
```

### Continue after review

```
User: /todo continue

Claude: Found in-flight todo: "Add unit tests for auth module"
Plan file: docs/todo_plans/add-unit-tests-for-auth-module.md

Pushing via /base-push...
  ✓ <branch> → origin/<branch>
  ✓ Merged into origin/<base> at commit <merge-hash>

Which agent should test? (or "skip notify" to skip)

User: tester

Claude: Sent notification to tester via /agent-send. They'll reply when
they've run the gates.

Cleaning up (after push + notify):
  ✓ Deleted docs/todo_plans/add-unit-tests-for-auth-module.md
  ✓ Removed todo section from docs/TODO.md
  ✓ Committed: chore(todo): finalize "Add unit tests for auth module"
    (commit is local; ships with your next push)

Done. The todo is fully closed:
  - Implementation pushed
  - origin/<base> includes the work
  - Testing agent notified (will reply asynchronously)
  - Plan file deleted, TODO entry removed locally

Would you like me to start the next todo? (or wait for testing results first)
```

### Skip planning

```
User: /todo do the next todo, skip plan

Claude: Executing "PROMPT: ..." directly (skip plan acknowledged).

[Executes; verifies; commits; runs doc-drift; stops for review]
```

## Quick reference

| Input pattern                            | Action                                                                                                                                                                                          |
| ---------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `/todo do the next todo`                 | Load docs (+ spec if linked) → Plan inline → Approve → Write plan file + `Status: planned` → Execute → **Verify** → **Commit** ([Spec NNN] prefix if linked) → **Doc-drift** (shape-aware) → `Status: committed` + `/tickets transition <id> "In Review"` (if ticket linked) → **STOP for review**                |
| `/todo do next`                          | Same                                                                                                                                                                                            |
| `/todo do the next todo, skip plan`      | Load docs (still) → Execute → **Verify** → **Commit** → **Doc-drift** → `Status: committed` → `/tickets transition` → **STOP**                                                                  |
| `/todo do the <keyword> todo`            | Search → (same as above)                                                                                                                                                                        |
| `/todo continue`                         | Idempotency check via `Status:` → `/base-push` (if not done) → `Status: shipping` → Notify tester (if not done, ask which agent) + `Notified:` line → `/tickets comment` (if ticket linked) → Cleanup (plan + TODO entry) → Commit cleanup → Report                                                            |
| `/todo continue, skip notify`            | Same minus notify; ticket comment also skipped                                                                                                                                                  |
| `/todo abandon`                          | Confirm via AskUserQuestion → ask reason → check working tree → `/tickets close <id> "Abandoned: <reason>"` (if ticket linked) → Delete plan file → Remove TODO entry → Commit `chore(todo): abandon` → Report                                                            |
| `/todo <text>`                           | Add as new todo header                                                                                                                                                                          |

## Parsing tips

- Split on `## ` to find sections.
- First line after `## ` is the header/title.
- Look for `Plan:` lines to find existing plans.
- Everything until the next `## ` or EOF is the content.
- Trim whitespace when extracting content.
- When removing, also clean up excessive blank lines.

## Companion skills

- **`base-pull`** — sync the current branch with the base branch.
- **`base-push`** — used by Mode 4 to push the implementation + advance `$WORKFLOW_BASE_BRANCH`.
- **`base-pr`** — review pending changes against the base in a sandbox.
- **`base-test`** — what the testing agent runs after Mode 4's notification.
- **`agent-send`** — used to dispatch review requests and tester notifications.
- **`agent-msg`** — what the tester (or reviewer) uses to reply back.
- **`tickets`** — generated by `define-tickets`; this skill calls `/tickets transition <id> "In Review"` at STOP (Mode 1/2), `/tickets comment <id> "Sent to <tester>..."` in Mode 4, and `/tickets close <id> "Abandoned: <reason>"` in Mode 5.
- **`define-product`** — owns `docs/specs/`; when a todo links to a spec via `Spec:` or title match, this skill auto-loads the spec into the plan context.
- **`define-architect`** — owns `docs/best-practices.md` / `docs/architecture.md` / `docs/api-conventions.md`; doc-drift respects their formats.
- **`define-qa`** — owns `docs/testing.md`; doc-drift respects its category structure.
- **`define-deploy`** — owns `docs/security.md` + `docs/deployment.md`; doc-drift slots into threat-model and runbook sections rather than appending.
- **`define-tickets`** — owns `docs/tickets.md`; conventions (state machine, title format, required fields) are read by this skill when constructing ticket transitions.
