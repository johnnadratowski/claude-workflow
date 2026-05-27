---
name: todo
description: Manage `docs/TODO.md` and drive a todo through the full lifecycle — plan (informed by `docs/best-practices.md` and the rest of the doc corpus) → execute → verify → commit → doc-drift check → STOP for review → continue after review → push base branch + notify testing agent → cleanup. Four modes: add, execute (next or by keyword), and continue (post-review).
---

# todo — full-lifecycle todo skill

Drives a todo through every phase: planning (informed by project docs), execution, verification, commit, doc-drift check, then a deliberate stop for human-driven review, then a continuation that pushes the base branch and notifies a testing agent before cleanup.

## File format

`docs/TODO.md` uses markdown headers to define todos. Each `##` header is a todo item, and the content below it (until the next header) is the description.

```markdown
## Fix the login bug

The login form times out after 30 seconds. Investigate the session handling.

## PROMPT: Review API security

Go through all API endpoints and check for authentication issues.
```

- Headers starting with `PROMPT:` are direct instructions for Claude to execute.
- Regular headers are task descriptions that require clarification before execution.
- Headers may include a `Plan:` link after a plan has been created.

## Planning is mandatory (with two narrow exceptions)

**Every TODO item MUST have a plan created before execution, unless:**

- The user explicitly says "skip plan", "no plan", or "just do it"
- The todo is trivially simple (single-line fix, typo, etc.)

### Load project docs BEFORE planning

Before creating any plan, load the project doc corpus. **`docs/best-practices.md` is the primary reference** — every plan must explicitly cite which best-practices rules apply.

```bash
cat docs/best-practices.md docs/architecture.md docs/security.md docs/testing.md docs/api-conventions.md 2>/dev/null
```

The `2>/dev/null` tolerates missing files — the corpus is whatever the project ships. If a project doesn't have `docs/best-practices.md` yet, the plan should still cite the project's `CLAUDE.md` rules and propose a `docs/best-practices.md` entry as part of the work (via the doc-drift step below).

The plan MUST:

- **Cite the specific best-practices rules** that apply to the work, by section name.
- Cite any architecture invariants the work depends on or could violate.
- Cite security rules if the work touches a sensitive surface.
- Respect existing patterns from the docs rather than inventing new ones.

If the plan would violate a documented rule, surface that conflict in the plan — don't quietly bypass.

### Planning workflow

**Note:** For non-PROMPT items, ask clarifying questions BEFORE step 1.

1. **Load docs**: `cat docs/best-practices.md docs/architecture.md docs/security.md docs/testing.md docs/api-conventions.md 2>/dev/null`
2. **Create plan**: Use `EnterPlanMode` to analyze the task against the doc corpus and produce an implementation plan
3. **Store plan**: Save to `docs/todo_plans/<todo-slug>.md`. Plan must include a "Best-practices rules this work touches" section.
4. **Link plan**: Update `docs/TODO.md` to add a `Plan:` link under the todo header
5. **Get approval**: Wait for user to approve via `ExitPlanMode`
6. **Execute**: Implement the approved plan, following the cited rules
7. **Verify**: Ask the user to verify the implementation works correctly. WAIT for confirmation.
8. **Commit**: After user confirms, create a git commit
9. **Doc-drift check**: Did the implementation introduce something that should be in the docs? Propose additions; apply approved ones; commit them.
10. **STOP for review**: Print the "Ready for review" summary. **Do NOT delete the plan file. Do NOT remove the todo from `docs/TODO.md` yet.** Wait for the user to drive review and then run `/todo continue`.

## Doc-drift check

After every implementation + commit, BEFORE stopping for review, run the doc-drift check. Order of priority:

1. **`docs/best-practices.md`** — Did this surface a new convention, a new pattern, or a new class of bug-fix that future code should follow? If yes → propose a new section (scenario + rule + how-to-apply).
2. **`docs/architecture.md`** — Did this introduce a new component, change a dependency direction, or add/strengthen an invariant?
3. **`docs/security.md`** — Did this touch a sensitive surface (auth, secrets, user data) in a new way?
4. **`docs/testing.md`** — Did this introduce a new test category or new test infrastructure?
5. **`docs/api-conventions.md`** — Did this add or change an API convention?

For each "yes", propose a concrete addition in **scenario + rule + how-to-apply** shape. **The user must explicitly approve before writing.** When approved, write the addition and commit it as a separate commit so the doc change is reviewable on its own (or amend the implementation commit if it's topical — user's call).

If nothing should be added, say so explicitly in the "Ready for review" summary. Don't silently skip — a "no, nothing to add" is a real outcome that confirms the check happened.

## Stop for review

After the doc-drift check, the skill STOPS. It does NOT delete the plan file. It does NOT remove the todo from `docs/TODO.md`.

The stop output should be:

```
✓ Implementation complete and committed (commit <hash>)
✓ Doc-drift check: <added N sections | nothing to add>

Ready for review.

Next steps:
1. Send to a reviewer for review:
     /agent-send <reviewer-name> "Please review commit <hash> on branch <branch>"

2. Address any review feedback with additional commits.

3. When review is complete, run:
     /todo continue

   That will push your branch up via /base-push (so origin/$WORKFLOW_BASE_BRANCH
   includes your work) and notify a testing agent. After tests come back green,
   the plan file and TODO entry will be cleaned up.
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

Assumes the user has driven the review handoff and (if needed) addressed feedback. This mode runs in this order so the TODO entry tracks the work's true state — the item stays in the list until the work is actually shipped AND the tester has been notified:

1. **Push the base branch** — invoke the `/base-push` skill. This pushes the current feature branch + advances `$WORKFLOW_BASE_BRANCH` to include the work.
2. **Notify the testing agent** — ASK the user for the testing agent's name (or use `WORKFLOW_TESTING_AGENT` from `.claude/workflow.config` if set). Then dispatch:
   ```bash
   "$(git rev-parse --show-toplevel)/.claude/scripts/agent-send.sh" <tester> \
     "Please /base-test on origin/$WORKFLOW_BASE_BRANCH at <merge-sha>. Reply with results."
   ```
3. **Cleanup (only AFTER notify)** — delete the plan file from `docs/todo_plans/<slug>.md` AND remove the todo's section from `docs/TODO.md`. Commit the cleanup as `chore(todo): finalize <todo title>`. The cleanup commit lives locally on the feature branch; it'll ship with the next push (no extra push needed — the TODO removal is housekeeping).
4. **Report** — confirm push, tester notification, and cleanup. Testing is asynchronous; the tester will reply via `/agent-msg` when done.

If the user opted out with "skip notify" / "no tester", step 2 is omitted but the cleanup in step 3 STILL runs after the push.

## How to determine mode

Parse the arguments:

1. **Continue (post-review)**: phrases like "continue", "finalize", "review done", "review is done", "promote".
2. **Execute next**: "do the next todo", "next todo", "do next", "next task", "do the next one".
3. **Search and execute**: "do the <keyword> todo/task".
4. **Add todo**: everything else.

## Implementation: Execute next todo

1. **Read `docs/TODO.md`**: Get current contents.
2. **Find first header**: Parse the first `## ` header and its content.
3. **Check for existing plan**: Look for a `Plan:` link in the section.
4. **Load docs corpus**: `cat docs/best-practices.md docs/architecture.md docs/security.md docs/testing.md docs/api-conventions.md 2>/dev/null` — use as planning context.
5. **If no plan exists**:
   a. Enter plan mode with `EnterPlanMode`.
   b. Analyze the task **AGAINST THE DOC CORPUS** — which best-practices rules apply? Which architecture invariants? Which security rules?
   c. Create a detailed plan that **explicitly cites the relevant doc sections** (a "Best-practices rules this work touches" header in the plan is mandatory).
   d. Save plan to `docs/todo_plans/<slug>.md`.
   e. Update `docs/TODO.md` to add the `Plan:` link.
   f. Exit plan mode with `ExitPlanMode` for user approval.
6. **Execute**: Follow the approved plan, respecting cited rules.
7. **Verify**: Ask the user to verify the implementation works. WAIT for confirmation.
8. **Commit**: After verification, create a git commit (conventional-commits style).
9. **Doc-drift check**: For each doc in the corpus, ask if this implementation introduced something that should be added. **Prioritize `docs/best-practices.md`.** Propose additions in scenario + rule + how-to-apply shape. WAIT for user approval. Apply approved additions + commit.
10. **STOP for review**: Print the summary (see "Stop for review" above). **Do NOT delete the plan file. Do NOT remove the todo from `docs/TODO.md`.**

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

1. **Identify the in-flight todo**: Look in `docs/todo_plans/` for plan files.
   - Exactly one plan file → use it.
   - Multiple → ask the user which slug.
   - None → error: "No in-flight todo to continue."
2. **Read the plan file** to recover the todo title (for the tester notification text + cleanup commit message).
3. **Push the base branch**: invoke the `/base-push` skill (or run the equivalent commands directly). This pushes the current feature branch + advances `$WORKFLOW_BASE_BRANCH`. Surface any push errors and STOP on failure (don't cleanup yet — the work isn't shipped).
4. **Notify the testing agent**: ask the user for the testing agent's name (or read `WORKFLOW_TESTING_AGENT` from `.claude/workflow.config` if set). Then run:
   ```bash
   "$(git rev-parse --show-toplevel)/.claude/scripts/agent-send.sh" <tester> \
     "Please /base-test the latest origin/$WORKFLOW_BASE_BRANCH (merge commit <hash>) — work from todo '<title>'. Reply with results."
   ```
   If the user said "skip notify" / "no tester", omit this step but still continue to cleanup.
5. **Cleanup** — ONLY after push + notify both completed:
   a. Delete the plan file: `rm docs/todo_plans/<slug>.md`.
   b. Remove the todo's section from `docs/TODO.md`.
   c. Commit the cleanup with message `chore(todo): finalize <todo title>`. (Local-only; ships with the next push.)
6. **Report**: confirm push + notify + cleanup. Note testing is async — the tester replies via `/agent-msg` when done. Mention that the cleanup commit is local; ships with the next push.

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

Skipping planning ALSO skips the docs-load step (docs inform the plan). The doc-drift check and stop-for-review steps still run.

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

## Best-practices rules this work touches

- `docs/best-practices.md` → "<Rule name>": <one-sentence relevance>
- `docs/best-practices.md` → "<Rule name>": <one-sentence relevance>
- `docs/architecture.md` → "<Invariant>": <one-sentence relevance>

(If no rules apply: state that explicitly with "No documented rules apply to this work — flagging this for the doc-drift step.")

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

**Cleanup happens in Mode 4 (Continue), not at the end of Mode 1/2.** The plan file and TODO entry persist through the review phase so that:

- The reviewer (a peer agent, or the user themselves later) can read the plan to understand intent.
- Re-running the skill in the middle of review doesn't lose state.

When Mode 4 runs, cleanup is the LAST step — AFTER the push and tester notification — so the TODO entry tracks the work's true state: it stays in the list until the work is shipped AND the tester has been notified. The cleanup commit is local; ships with the next push.

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

Paths are relative to the repo root:

- TODO file: `docs/TODO.md`
- Plans directory: `docs/todo_plans/`
- Best-practices: `docs/best-practices.md` (primary reference for plans and doc-drift)
- Architecture: `docs/architecture.md`
- Security: `docs/security.md`
- Testing: `docs/testing.md`
- API conventions: `docs/api-conventions.md`

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
| `/todo do the next todo`                 | Load docs → Plan → Approve → Execute → **Verify** → **Commit** → **Doc-drift** → **STOP for review**                                                                                            |
| `/todo do next`                          | Same                                                                                                                                                                                            |
| `/todo do the next todo, skip plan`      | Execute directly → **Verify** → **Commit** → **Doc-drift** → **STOP for review**                                                                                                                |
| `/todo do the <keyword> todo`            | Search → Load docs → Plan → Execute → **Verify** → **Commit** → **Doc-drift** → **STOP for review**                                                                                             |
| `/todo continue`                         | `/base-push` → Notify tester (ask which agent) → Cleanup (plan + TODO entry) → Commit cleanup (local; ships with next push) → Report                                                            |
| `/todo continue, skip notify`            | `/base-push` → Cleanup → Commit cleanup → Report (no tester notification)                                                                                                                       |
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
