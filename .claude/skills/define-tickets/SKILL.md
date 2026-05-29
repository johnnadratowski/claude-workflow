---
name: define-tickets
description: Set up the project's ticketing-system integration (Jira, Linear, GitHub Issues, etc.), write `WORKFLOW_PROJECT_ID` to `.claude/workflow.config`, generate a project-local `/tickets` skill tailored to the chosen provider and integration method (MCP, CLI, or API), then use that generated skill to seed tickets from `docs/specs/*.md` and link the ticket IDs back into each spec. On re-entry, becomes the orchestration point for "add tickets for new specs", "pull my assigned tickets into local todos", and "mark this todo done and update the ticket".
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

### Phase D: generate `.claude/skills/tickets/SKILL.md`

Write a project-local `/tickets` skill tailored to the chosen provider + integration. The generated skill must support these three operations as separate sub-commands or sub-modes:

- **`/tickets create`** — accepts a spec file (or content) and creates a ticket. Returns the ticket ID + URL. Used by `define-tickets` to seed and by the user on demand.
- **`/tickets list`** — lists tickets, optionally filtered (assignee = current user, status, etc.). Used to pull tickets into local todos.
- **`/tickets update`** — updates a ticket (status transition, comment, link a PR, mark done).

The generated SKILL.md should:

1. Have frontmatter `name: tickets` and a `description:` that names the provider + integration method.
2. Document the exact shell commands or MCP tool names that wrap each operation, parameterized on `$WORKFLOW_PROJECT_ID`.
3. Define how spec ↔ ticket mapping is recorded: the `## Tickets` section in each spec file gets a bullet `- [<ticket-id>](<url>) — <title>` appended per ticket. **Never strip an existing bullet** — only append.
4. Handle the empty-state case: if a spec has no `## Tickets` section yet (shouldn't happen with the `define-product` template, but defensively), append one.

#### Template by integration method

The generation step picks a template based on `WORKFLOW_TICKET_INTEGRATION`. Sketches:

**MCP-based** (assuming a provider MCP is available):
- Each operation maps to one `mcp__<server>__<tool>` call
- Token / auth managed by the MCP server, not the skill
- Skill body: list which MCP tools to call, with what arguments, for each operation

**CLI-based**:
- Wraps `jira issue create ...`, `linear issue create ...`, `gh issue create ...` etc.
- Skill body: exact CLI invocation per operation, including how `WORKFLOW_PROJECT_ID` flows in
- Note: the CLI auth happens out-of-band (one-time `jira login` / `gh auth login`); the skill assumes that's done

**API-based**:
- `curl` invocations with `$<PROVIDER>_TOKEN` from env
- Skill body: full curl recipe per operation, including pagination handling for `list`
- Add a one-time-setup note: where to get a token, what scopes are needed, where it should land (`.env`)

The generated skill is committed to the repo so every clone gets the same integration. Add it to git in the orchestrator's final commit.

### Phase E: seed tickets from existing specs

Now use the just-generated `/tickets` skill (via the Skill tool) to create one ticket per spec in `docs/specs/*.md`.

For each spec, in numeric order:

1. Read the spec file
2. Build the ticket body from `## Summary` + `## User-visible behavior` + `## Acceptance criteria`. Reference the spec file path in the body so a developer reading the ticket can find it.
3. Call `/tickets create` with the assembled body. Capture the returned ticket ID + URL.
4. Append `- [<ID>](<url>) — <spec title>` to the spec's `## Tickets` section. Remove the placeholder `_No tickets created yet._` line if present.

If a spec already has tickets listed in its `## Tickets` section, skip it (the spec was previously seeded — don't double-create).

After all specs are seeded, summarize: N tickets created, with the ID range and the spec range they correspond to.

### Phase F: critical review

Spawn **2 subagents in parallel**:

1. **Integration completeness critic** — read the generated `.claude/skills/tickets/SKILL.md`. List operations that are documented but not actually invokable (referenced tools that don't exist, missing args, auth gaps). 400 words.
2. **Sync correctness critic** — read every `docs/specs/*.md`. List specs whose `## Tickets` section is missing, malformed, or empty after seeding. 400 words.

Present findings, fix, iterate.

### Phase G: signoff

`AskUserQuestion`:

- **Sign off and return to `define-project`** (recommended)
- **One more dialog pass on the integration**
- **Re-seed tickets** (delete the seeded ones first — ask user to confirm in their ticketing system before this destructive op)

## Re-entry mode

When `.claude/skills/tickets/SKILL.md` already exists, `define-tickets` becomes a router. Ask via `AskUserQuestion`:

> "What do you want to do with tickets?"

- **Add tickets for new specs** — scan `docs/specs/*.md`, find any whose `## Tickets` section is empty (or contains only the placeholder line), and run the Phase E seed loop on just those.
- **Pull my assigned tickets into local todos** — call `/tickets list assignee:me`. For each returned ticket, append a new section to `docs/TODO.md`:

  ```markdown
  ## PROMPT: <ticket title> (<ticket-id>)

  <ticket body, abridged to first 500 chars>

  - Assigned to: <user>
  - Ticket: <url>
  - Spec: <linked spec file if discoverable from the ticket body>
  ```

  Don't duplicate — skip any ticket whose ID already appears in `docs/TODO.md`.
- **Mark a todo done and update its ticket** — ask which todo. Find its ticket ID (from the section's `Ticket:` line). Call `/tickets update <id> --status done` (or whatever the generated skill's syntax is). Remove the todo section from `docs/TODO.md`. Commit.
- **Reconfigure the integration** — re-enter Phase A–D from the first-run path. This rewrites the generated `/tickets` skill. Warn the user that existing ticket links in specs may need re-validation against the new project.

The orchestrator's "What do you want to update?" routing eventually calls into this; user can also invoke `/define-tickets` directly.

## What this skill will NOT do

- Modify tickets without explicit user confirmation in re-entry mode (every write through `/tickets update` is gated on the user's request).
- Bulk-delete tickets to "clean up" the project. If the user wants that, they do it in the provider's UI.
- Store API tokens / credentials in repo files. Tokens go in `.env` (gitignored) or the user's preferred secrets store.
- Touch spec numbering. New specs use new numbers; existing specs are append-only.

## Companion skills

- `define-project` — orchestrator that calls this.
- `define-product` — produced the specs that this skill seeds tickets for. The `## Tickets` section in each spec is the contract between the two skills.
- `tickets` (generated by Phase D) — the runtime CRUD skill for the chosen provider.
- `todo` — manages `docs/TODO.md` items; the "pull assigned tickets into local todos" path in re-entry mode feeds into `/todo`.
