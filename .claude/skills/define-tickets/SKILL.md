---
name: define-tickets
description: Set up the project's ticketing-system integration (Jira, Linear, GitHub Issues, etc.), write `WORKFLOW_PROJECT_ID` to `.claude/workflow.config`, drill the user on ticket-structure decisions (issue types, state machine, title convention, definition of ready/done, spec↔ticket cardinality, etc.) writing them to `docs/tickets.md`, generate a project-local `/tickets` skill tailored to the chosen provider + integration method + those decisions, then seed tickets from `docs/specs/*.md` and link the ticket IDs back into each spec. On re-entry, becomes the orchestration point for "add tickets for new specs", "pull my assigned tickets into local todos", "mark this todo done and update the ticket", "detect drift between specs and their tickets", "find orphan tickets whose specs were deleted", and "bulk close obsolete tickets".
---

# define-tickets — ticketing integration + spec-to-ticket sync

Two modes, separated by whether `.claude/skills/tickets/SKILL.md` exists:

- **First run** (no generated skill yet): dialog → configure provider → generate `/tickets` → seed tickets from specs
- **Re-entry** (generated skill exists): orchestrate add / pull / complete workflows on top of the generated `/tickets` skill

## Re-entry detection

```bash
if [ -f .claude/skills/tickets/SKILL.md ]; then
  mode="reentry"
else
  mode="first-run"
fi
```

On re-entry, also scan `docs/tickets.md` for `## Open questions` — bullets there are ticket-structure areas the user deferred during a prior pass. Surface them first as natural starting points (same pattern as the other `define-*` skills).

## First-run

### Phase A: pick the provider

`AskUserQuestion`:

> "Do you want to wire this project up to a ticketing system? If yes, which one?"

Multi-option (single-select):

- **Jira**
- **Linear**
- **GitHub Issues** (recommended for OSS / GitHub-resident projects)
- **None — skip ticketing**

If "none", record a note in `.claude/workflow.config` (commented `# WORKFLOW_PROJECT_ID=` with a hint that ticketing is intentionally off) and return to `define-project`. Otherwise continue.

### Phase B: integration method

For the chosen provider, ask which integration the user wants. `AskUserQuestion`:

> "How should I talk to <provider>?"

Provider-specific options:

- **MCP server** (recommended if one is installed and configured) — Claude can call MCP tools directly. Check whether the relevant MCP server is listed in available skills / tools before recommending. Examples: an `atlassian` MCP for Jira, a `linear` MCP, etc.
- **CLI** — the provider's official CLI (`jira`, `linear`, `gh`). Check whether it's installed before recommending; if not installed, give the install command.
- **HTTP API** — direct curl/HTTP calls with an API token. Slowest path, but always works. Token storage: `.env` (gitignored) or a secrets manager — ask the user.

If a method isn't viable for the environment (no MCP installed, no CLI, no token), say so and propose another.

### Phase C: project setup

Ask:

> "Is there an existing <provider> project for this, or should I create one?"

If existing: ask for the project key / ID / URL.

If new: walk the user through creation. Depending on the chosen integration method:
- MCP / CLI / API: drive the creation programmatically — gather name + key + lead from the user, then call the provider.
- If creation requires UI steps the integration can't automate (Jira project templates, for instance), give the user a checklist and ask for the resulting project key when done.

Store the result in `.claude/workflow.config`:

```bash
sed -i.bak "s|^# WORKFLOW_PROJECT_ID=.*|WORKFLOW_PROJECT_ID=\"<key>\"|" .claude/workflow.config
sed -i.bak "s|^# WORKFLOW_TICKET_PROVIDER=.*|WORKFLOW_TICKET_PROVIDER=\"<provider>\"|" .claude/workflow.config
sed -i.bak "s|^# WORKFLOW_TICKET_INTEGRATION=.*|WORKFLOW_TICKET_INTEGRATION=\"<mcp|cli|api>\"|" .claude/workflow.config
rm -f .claude/workflow.config.bak
```

If the config file doesn't have placeholders for these keys yet, append them at the bottom of the relevant section.

### Phase D: drill ticket-structure decisions

Before generating the `/tickets` skill, drill the user on the conventions that skill will enforce. Same two-level loop as `define-product` / `define-architect` / `define-qa` / `define-deploy`.

**Inner loop — depth on a single area.** Pick an area. Drill with `AskUserQuestion` (2–4 questions per turn). Write to `docs/tickets.md`. Ask: "Want to go deeper here, or have we covered this enough?"

**Outer loop — area coverage.** Once an area is "enough", suggest the next one (or let the user pick). The user can call it done at any time — areas not covered are recorded as `## Open questions` in `docs/tickets.md` for next time, AND the generated `/tickets` skill inherits the provider's default behavior for that area (rather than enforcing a project-specific rule the user hasn't made).

**Create `docs/tickets.md` if it doesn't exist** with a `# Tickets` heading and short intro: "Ticketing-system conventions for this project. The `/tickets` skill enforces these; `/define-tickets` re-entry can update them."

#### Critical-reviewer role

Push back on the usual vague claims:

- "We'll figure out the state machine as we go" — provider defaults are weak; the cost of not deciding is wrong-status tickets, missing transitions, broken automation. Press for at least the 3-4 statuses that actually get used.
- "We'll triage as we go" — same. Triage without a rule is bias.
- "Standard JIRA workflow" — which one? There are dozens.

#### The area list

**★** = essentials (load-bearing for any project that uses tickets). **⚙** = process-discipline (looks optional but quietly determines whether the ticketing system stays useful over time).

##### Ticket structure + taxonomy

- **★ Issue types** — Epic / Story / Task / Bug / Sub-task? Spike? Each provider has different defaults; pick which ones this project actually uses.
- **★ Spec → ticket cardinality** — one spec = one ticket? one spec = one epic + N stories? When does a spec split into multiple tickets?
- **★ Title convention** — recommend `[Spec NNN] <title>` so both directions grep cleanly. Without it the link is one-directional.
- **Labels / tags** — what taxonomy (area, type, priority, risk-tier)? Locked vocabulary or free-form?
- **Components / epics / fix-versions** — provider-specific containers; do you populate them?
- **Custom fields** — provider has them; which matter? (story points, team, "QA needed", etc.)

##### Workflow + states

- **★ State machine** — which statuses exist (Backlog / Ready / In Progress / In Review / Done / etc.) and what transitions are legal
- **★ Definition of Ready** — what makes a ticket pickup-able. Often unwritten; write it.
- **★ Definition of Done** — same. Tied directly to spec acceptance criteria.
- **WIP limits** — per assignee? per swimlane?
- **⚙ Stale-ticket policy** — what happens to tickets that haven't moved in N days

##### Assignment + ownership

- **★ Assignment model** — self-assign? PM-assigns? Round-robin? On-call rotates?
- **Reviewer / approver fields** — who gates "done"
- **⚙ Team / squad mapping** — which tickets go to which team

##### Estimation + planning

- **Estimation scheme** — story points / t-shirt / no-estimate-by-policy. Pick one (or pick "none and we don't pretend").
- **Sprints / cadence** — sprint length, ceremonies, or kanban-only?
- **Roadmap views** — provider-specific (Jira roadmap, Linear project view, GitHub milestones)

##### Linking + relationships (load-bearing for spec ↔ ticket sync)

- **★ Spec ↔ ticket bidirectionality** — current skill writes ticket-into-spec; also write spec-link-into-ticket-body so a ticket reader can find the source
- **★ PR ↔ ticket linking** — `<ticket-id>` in PR title / commit message / branch name (most providers auto-link)
- **Blocked-by / blocks** — when to set these, who maintains them
- **Duplicate handling** — what's the canonical-ticket rule

##### Spec sync semantics

- **★ Spec edit → ticket update?** — when `docs/specs/NNN-*.md` changes, does the linked ticket update too? Push? Pull? Manual?
- **★ Spec deletion** — what happens to the ticket(s) attached to a deleted/obsoleted spec? (Close as obsolete? Manual confirmation? Leave?)
- **Section sync scope** — sync Summary + Acceptance Criteria? Just title? (Sync risk increases with scope.)
- **⚙ Drift detection** — telemetry on specs whose tickets have diverged

##### Bug / non-spec tickets

- **★ Bugs vs spec'd work** — bugs usually have no spec; they live in tickets only. Where does the "every bug needs a regression test" rule (from `define-qa`) get tracked?
- **Triage workflow** — new bug → triage → backlog or close
- **Severity vs priority** — distinct fields, distinct meanings; pick how each is set

##### Notifications + comms

- **Notification routing** — which events go to Slack / email / nowhere
- **⚙ "I picked this up" announcement** — does someone announce they started?
- **⚙ Standup integration** — daily report from the provider?

#### How to surface the list

Don't dump the whole tree. Lead with a recommendation (one missing essential), or show category headings via `AskUserQuestion`. Always offer "I'm done overall" as an option in the outer loop.

### Phase E: generate `.claude/skills/tickets/SKILL.md`

Write a project-local `/tickets` skill tailored to the chosen provider + integration method + the conventions captured in `docs/tickets.md` (Phase D).

#### Required operations

The generated skill must support every operation below. Each is a separate sub-command or sub-mode (e.g. `/tickets <verb> <args>`):

**Read operations**

- **`get <id>`** — fetch a single ticket's full state (title, status, assignee, comments, link list)
- **★ `search <query>`** — provider-specific search syntax. The skill body must include 3–5 example queries (e.g., Jira JQL examples, Linear filter syntax, GitHub `is:open author:@me`). This is the workhorse — most lookups go through here.
- **`list-mine`** — sugar for "tickets assigned to me", the most common query
- **`list-spec NNN`** — tickets linked to a specific spec (greps the spec's `## Tickets` section + verifies the IDs are still valid against the provider)
- **`list <filter>`** — generic list with provider-native filter syntax
- **`whoami`** — diagnostic: who the skill thinks the current user is (critical for debugging "list-mine returns empty")
- **`ping`** — sanity-check the integration can reach the provider; surface useful diagnostics on failure

**Write operations** (each must accept `--dry-run`)

- **`create`** — generic ticket creation from prompt-supplied body
- **`from-spec <spec-path>`** — create a ticket from a spec file (used by Phase F seeding *and* by the user on demand)
- **`update <id> <field>=<value>`** — field-level updates
- **`transition <id> <state>`** — state-machine transition; separate from `update` so the skill can enforce the state machine from `docs/tickets.md`
- **`comment <id> <body>`** — add a comment without changing state
- **`assign <id> <user>`**
- **`link <a> <b> <relationship>`** — blocked-by / blocks / relates-to / duplicate-of
- **`close <id> <reason>`** — wraps the canonical "mark done" workflow with the project's exit reason
- **`sync-spec <spec-path>`** — push spec changes to the linked tickets (only if the provider supports body updates AND `docs/tickets.md` opted into spec-edit-sync)

**Local-todo bridges**

- **`to-todo <id>`** — pull a ticket into `docs/TODO.md` (the re-entry "pull assigned" workflow but for a single ticket)
- **`from-todo <todo-section>`** — create a ticket from an existing local todo

**Bulk operations**

- **`bulk-update <filter> <changes>`** — always prints the change plan + asks for confirmation, even when `--dry-run` is *not* passed (this is the only operation gated on a confirmation rather than a flag, because the blast radius is high)

#### Flags on every command

- **`--json`** — machine-readable output (so other skills can pipe it); default is human-readable
- **`--dry-run`** — on every write operation; prints what would happen without doing it

#### Skill behavior requirements

The generated SKILL.md must:

1. Frontmatter: `name: tickets`, and a `description:` that names the provider + integration method + the conventions from `docs/tickets.md` the skill enforces (e.g. "Title convention `[Spec NNN] ...`; state machine: Backlog → Ready → In Progress → In Review → Done").
2. Document the exact shell commands / MCP tool names / API endpoints wrapping each operation, parameterized on `$WORKFLOW_PROJECT_ID` (and other `$WORKFLOW_TICKET_*` config keys as needed).
3. Define the spec ↔ ticket mapping convention:
   - The `## Tickets` section in each spec file gets `- [<ticket-id>](<url>) — <title>` appended per ticket. **Never strip an existing bullet** — only append.
   - Tickets created from a spec must include the spec path *and* a link to the spec in the ticket body (so a ticket reader can navigate back).
4. Handle the empty-state case: if a spec has no `## Tickets` section, append one (defensive — the `define-product` template ships with one, but obsoleted templates may not).
5. **Title-convention enforcement**: before creating a ticket, verify the title matches what `docs/tickets.md` prescribes (e.g. `[Spec NNN] ...`). Refuse with a clear error message pointing at the relevant `docs/tickets.md` section.
6. **Required-field validation**: before creating, ensure every required custom field has a value. Refuse if not.
7. **Token sourcing chain**: document where the auth token comes from in priority order — typically `.env` → user keychain → 1Password CLI → interactive prompt. Pick one as primary, document the fallback explicitly.
8. **Token-expired UX**: when the token is rejected, the skill explains exactly how to refresh it and where to put the new one. Don't fail silently or with a stack trace.
9. **Pre-flight auth check**: every invocation runs a cheap `whoami`-style call first; if it fails, surface the friendly error from step 8 and exit before doing the user's real work.
10. **Audit log**: every write operation appends a line to `.claude/skills/tickets/audit.log` (add to `.gitignore`) with timestamp + operation + target ID + result. Forensic value when something went sideways.
11. **Idempotency on seeding**: when called with `from-spec`, check the spec's `## Tickets` section first — if non-empty, refuse with "already seeded; pass `--force` to re-seed".
12. **Template files**: write `.claude/skills/tickets/templates/spec-ticket.md` and `.claude/skills/tickets/templates/bug-ticket.md`. These are user-editable starting points; the skill reads them when constructing ticket bodies. The bug template should include a "Regression test added" field tying back to the `define-qa` rule.
13. **Inline "Gotchas for this provider" section** — top 3–5 issues unique to the chosen provider (sketches below).
14. **Recognize project-ID mismatch on startup**: if `WORKFLOW_PROJECT_ID` was changed in config after this skill was generated, warn ("you're calling `/tickets` with project ID X, but the config now says Y — was the migration intentional?") before doing any work.

#### Provider-specific gotchas to inline

The generated skill's "Gotchas" section is customized per provider. Cover at least:

- **Jira** — custom-field IDs (`customfield_10001`) vs human names; transition names are case-sensitive and only resolvable via API; project-key vs internal-ID confusion; JQL operator precedence
- **Linear** — UUID vs human-readable identifier (e.g. `ENG-123`); state *types* vs state *names*; team-scoped vs workspace-scoped queries
- **GitHub Issues** — label-as-state pattern (labels often substitute for a state machine); Milestones vs Projects-v2 have different capabilities; rate limit per-token; no built-in custom fields (use label conventions)
- **GitLab Issues** — similar to GitHub but with iterations; group-vs-project scope confusion; quick-action syntax in body
- **Asana** — sections vs columns vs custom-field-dropdowns can all encode state
- **Trello** — list = state; archived ≠ closed; per-board scope

If the provider isn't in the list above, ask the user for the top 3 things that bit them in the past on this provider, and document those.

#### Template by integration method

The generation step picks a template based on `WORKFLOW_TICKET_INTEGRATION`:

**MCP-based** (when a provider MCP is available):
- Each operation maps to one `mcp__<server>__<tool>` call
- Token / auth managed by the MCP server, not the skill
- Skill body: list which MCP tools to call, with what arguments, per operation
- `whoami` / `ping` map to the simplest read tool on the MCP

**CLI-based**:
- Wraps `jira issue create ...`, `linear issue create ...`, `gh issue create ...`, `glab issue create ...` etc.
- Skill body: exact CLI invocation per operation, including how `WORKFLOW_PROJECT_ID` flows in
- CLI auth happens out-of-band (one-time `jira login` / `gh auth login`); the skill assumes that's done and surfaces a useful error if not (referenced by the "Token-expired UX" requirement above)
- `--json` flag uses the CLI's native JSON output mode

**API-based**:
- `curl` invocations with `$<PROVIDER>_TOKEN` from `.env`
- Skill body: full curl recipe per operation, including pagination handling for `search` and list ops
- One-time-setup note: where to get a token, what scopes are needed, where it lands (`.env`), what's in `.gitignore`
- `search` typically requires URL-encoding the query — show the exact pattern

The generated skill is committed to the repo so every clone gets the same integration. Add it (plus `.claude/skills/tickets/templates/`) to git in the orchestrator's final commit. Add `.claude/skills/tickets/audit.log` to `.gitignore` in the same commit.

### Phase F: seed tickets from existing specs

Now use the just-generated `/tickets` skill (via the Skill tool) to create one ticket per spec in `docs/specs/*.md`.

For each spec, in numeric order:

1. Read the spec file
2. Build the ticket body from `## Summary` + `## User-visible behavior` + `## Acceptance criteria`. Reference the spec file path in the body so a developer reading the ticket can find it.
3. Call `/tickets from-spec <spec-path>` with the spec file. The generated skill handles building the body, validating the title format, applying the spec-ticket template, and creating the ticket. Capture the returned ticket ID + URL.
4. Append `- [<ID>](<url>) — <spec title>` to the spec's `## Tickets` section. Remove the placeholder `_No tickets created yet._` line if present.

If a spec already has tickets listed in its `## Tickets` section, skip it (the spec was previously seeded — don't double-create). The generated skill's idempotency check (requirement 11 in Phase E) also catches this.

After all specs are seeded, summarize: N tickets created, with the ID range and the spec range they correspond to.

### Phase G: critical review

Spawn **3 subagents in parallel** (one more than the original because the area menu in Phase D expanded the surface area):

1. **Integration completeness critic** — read the generated `.claude/skills/tickets/SKILL.md`. List operations that are documented but not actually invokable (referenced tools that don't exist, missing args, missing flags, auth gaps). 400 words.
2. **Sync correctness critic** — read every `docs/specs/*.md`. List specs whose `## Tickets` section is missing, malformed, or empty after seeding. 400 words.
3. **Convention-alignment critic** — read `docs/tickets.md` + the generated `.claude/skills/tickets/SKILL.md`. List rules from `docs/tickets.md` that the generated skill doesn't actually enforce (title convention, required fields, state-machine guardrails, etc.). 400 words.

Present findings, fix, iterate.

### Phase H: signoff

`AskUserQuestion`:

- **Sign off and return to `define-project`** (recommended)
- **One more dialog pass on the conventions** (re-enters Phase D)
- **Re-generate the `/tickets` skill** (re-runs Phase E with the current `docs/tickets.md` state)
- **Re-seed tickets** — destructive; ask the user to close / delete the previously-seeded tickets in their ticketing system first

## Re-entry mode

When `.claude/skills/tickets/SKILL.md` already exists, `define-tickets` becomes a router. **First**, scan `docs/tickets.md` for `## Open questions` — if any are present, surface them as available workflows ("you parked these last time — want to revisit any of them now?"). **Then** ask via `AskUserQuestion`:

> "What do you want to do with tickets?"

#### Sync workflows (extend the seeded state)

- **★ Add tickets for new specs** — scan `docs/specs/*.md`, find any whose `## Tickets` section is empty (or contains only the placeholder line), and run the Phase F seed loop on just those.
- **★ Detect spec ↔ ticket drift** — for each spec, call `/tickets get <id>` per linked ticket. Compare ticket body against the spec's current Summary + Acceptance Criteria. Surface specs where they've diverged. For each: offer (a) push spec → ticket via `/tickets sync-spec`, (b) update spec to match ticket, (c) record as `## Open questions` and defer.
- **★ Detect orphan tickets** — call `/tickets search` for all tickets linked to this project. Identify any whose linked spec no longer exists in `docs/specs/` (or whose spec is marked obsolete). For each: offer (a) close the ticket as obsolete via `/tickets close <id> "spec deleted"`, (b) re-link to a different spec, (c) leave alone.
- **★ Bulk close obsolete tickets** — explicit user-confirmed bulk action when the orphan-detection step finds many. Always shows the list and asks for confirmation before any write, even with `--dry-run`.

#### Todo bridges (extend `docs/TODO.md`)

- **★ Pull my assigned tickets into local todos** — call `/tickets list-mine`. For each returned ticket, append a new section to `docs/TODO.md`:

  ```markdown
  ## PROMPT: <ticket title> (<ticket-id>)

  <ticket body, abridged to first 500 chars>

  - Assigned to: <user>
  - Ticket: <url>
  - Spec: <linked spec file if discoverable from the ticket body>
  ```

  Don't duplicate — skip any ticket whose ID already appears in `docs/TODO.md`.

- **★ Mark a todo done and update its ticket** — ask which todo. Find its ticket ID (from the section's `Ticket:` line). Call `/tickets transition <id> done` (or whatever the project's terminal state is, per `docs/tickets.md`). Remove the todo section from `docs/TODO.md`. Commit.

- **Pull comments from a ticket back into spec context** — for a chosen spec, fetch comments on its linked tickets and append a `## Recent ticket discussion` section to the spec (or update an existing one). Useful when reviewing a spec before starting work.

#### Convention updates

- **Update ticket conventions** — re-enter Phase D to drill more areas (or revise existing ones in `docs/tickets.md`). After conventions change, ask if the user wants to **re-generate** the `/tickets` skill so new tickets follow updated rules. Existing tickets are NOT migrated automatically.

#### Integration reconfiguration

- **Reconfigure the integration** — re-enter Phases A–C (provider / integration method / project setup), then Phase E (re-generate `/tickets`). Warn the user that existing ticket links in specs may need re-validation against the new project. Records the change as a dated entry in `docs/tickets.md` under `## Integration history`.

#### Diagnostics

- **Run `/tickets ping` + `/tickets whoami`** — quick health check on the integration without touching any data. Useful when something's flaky.

The orchestrator's "What do you want to update?" routing eventually calls into this; user can also invoke `/define-tickets` directly.

## What this skill will NOT do

- Modify tickets without explicit user confirmation in re-entry mode (every write through `/tickets` is gated on the user's request, and bulk operations always print a plan + ask for confirmation).
- Bulk-delete tickets to "clean up" the project. The closest it gets is **bulk close as obsolete** (a transition, not a destroy), and only after explicit confirmation. If the user wants real deletion, they do it in the provider's UI.
- Store API tokens / credentials in repo files. Tokens go in `.env` (gitignored) or the user's preferred secrets store; the generated `/tickets` skill's "Token sourcing chain" documents which.
- Touch spec numbering. New specs use new numbers; existing specs are append-only.
- Auto-migrate existing tickets when conventions change. After a Phase D revision and `/tickets` regeneration, *new* tickets follow the updated rules — existing ones stay as-is unless the user explicitly runs a bulk-update.

## Companion skills

- `define-project` — orchestrator that calls this.
- `define-product` — produced the specs that this skill seeds tickets for. The `## Tickets` section in each spec is the contract between the two skills.
- `tickets` (generated by Phase E) — the runtime CRUD skill for the chosen provider. Operations: `get`, `search`, `list-mine`, `list-spec`, `list`, `whoami`, `ping`, `create`, `from-spec`, `update`, `transition`, `comment`, `assign`, `link`, `close`, `sync-spec`, `to-todo`, `from-todo`, `bulk-update`. All write ops support `--dry-run`; all ops support `--json`.
- `todo` — manages `docs/TODO.md` items; the "pull assigned tickets into local todos" path in re-entry mode feeds into `/todo`.
