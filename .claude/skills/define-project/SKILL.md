---
name: define-project
description: Interactive, multi-stage project definition flow. Drives a deep dialog with the user across product → architect → QA → deploy/security → ticketing, populating `docs/` with detailed specs, scaffolding code where applicable, and seeding a ticketing system at the end. Each stage is a dedicated subskill (`define-product`, `define-architect`, `define-qa`, `define-deploy`, `define-tickets`) with subagent-driven critical review and user signoff gates. On re-entry (after the codebase is initialized) it asks which stage to update and re-runs only that subskill in update mode.
---

# define-project — orchestrator for project definition

Top-level interactive flow that calls five subskills in sequence, each owning one domain of the project's documentation + scaffold:

| Order | Subskill | Owns | Produces |
|---|---|---|---|
| 1 | `define-product` | What the product does and for whom | `docs/product.md`, `docs/specs/NNN-*.md` |
| 2 | `define-architect` | How it's built (no testing, no deploy details) | `docs/architecture.md`, `docs/api-conventions.md`, `docs/best-practices.md`, initial code scaffold |
| 3 | `define-qa` | How it's tested | `docs/testing.md`, test scaffold |
| 4 | `define-deploy` | How it's deployed + what it must defend against | `docs/deployment.md`, `docs/security.md` |
| 5 | `define-tickets` | Ticketing integration + spec → ticket sync | `.claude/skills/tickets/SKILL.md` (generated), `WORKFLOW_PROJECT_ID` in `.claude/workflow.config`, tickets seeded from `docs/specs/` |

`define-project` is called by `base-initialize` Phase 9. It can also be invoked standalone at any time.

## When to Use

- `base-initialize` Phase 9 invokes this automatically.
- User says "set up the project docs / specs", "let's design the project", "/define-project".
- User wants to update one domain after the project is already initialized (this skill detects that and routes to update mode).

## First-run vs re-entry detection

Before asking anything, check whether `docs/product.md` already exists AND its first line is not the template stub (`# Product`).

```bash
if [ -f docs/product.md ] && ! head -1 docs/product.md | grep -qE '^#\s*Product\s*$'; then
  mode="reentry"
else
  mode="first-run"
fi
```

Heuristic, not load-bearing — if it gets the wrong answer occasionally, that's fine; the user redirects.

### First-run path

Walk the five subskills in order. Each one:

1. Runs its interactive dialog
2. Writes / updates its docs
3. Spawns subagent critics, presents findings, iterates until clean
4. Asks the user to sign off before the orchestrator advances to the next subskill

After `define-tickets` finishes, print the final summary (per "Phase 11: Report" of `base-initialize`).

### Re-entry path

Ask via `AskUserQuestion`:

> "The project's already defined. Which domain do you want to update?"

Single-select options:

- **Product** — what the product does / specs
- **Architecture** — how it's built / code scaffold
- **Testing** — test strategy / test scaffold
- **Deployment & security** — deploy + threat model
- **Tickets** — ticketing integration / spec→ticket sync
- **Multiple** (free-form follow-up)

Route to the corresponding subskill in `--update` mode (each subskill detects re-entry on its own too, so this routing is mostly UX — the subskill is authoritative). When `Multiple`, ask which ones and call them in the canonical order (product → architect → qa → deploy → tickets).

## Common pattern enforced across all five subskills

This is the shared shape every subskill follows. It's documented here so the subskills can reference it instead of repeating it.

### 1. Dialog loop

Loop of `AskUserQuestion` + free-form replies, **with the assistant playing a critical PM / architect / QA lead / SRE / etc. role appropriate to the subskill**. Rules for the assistant:

- **Drill from coarse to fine.** Start with one open question ("describe the product"), then ask 2–4 targeted follow-ups per turn. Each follow-up should narrow on something the previous answer left ambiguous.
- **Challenge unclear answers.** If the user says "it should be fast," push back: how fast? P99 under what load? On what hardware? Drop the question if the answer truly doesn't matter for documentation purposes; otherwise keep drilling.
- **Make suggestions of your own.** Don't be a stenographer. Propose features / patterns / pitfalls the user hasn't mentioned. Frame as suggestions, not demands.
- **Flag design flaws.** When the user describes something that contradicts an earlier decision, or has a known failure mode, or leaves an obvious gap, raise it explicitly before moving on.
- **Loop until the user says "I'm done"** (or equivalent). At each turn give the user the option to call it done. Don't bury that option.
- **For the architect subskill specifically: technology decisions are user-driven, but you challenge them.** If the user picks something that's a poor fit, say so + suggest alternatives. They still decide.

### 2. Documentation writes

The subskill owns specific files (see the table above). As the dialog progresses, **write to those files incrementally** — don't wait until the end. Use a "draft then confirm" loop: write what you've understood, show the diff (or the new section), ask the user to confirm before moving on.

If a doc grows past ~500 lines or covers multiple loosely-coupled topics, split it: create `docs/<domain>/<topic>.md` and link to it from the main doc. The split should be a natural concern boundary, not a line-count threshold.

### 3. Subagent critical review

After the user says "I'm done," spawn **2–3 subagents in parallel** (single message, multiple Agent tool calls) — `subagent_type: general-purpose` — each with a critic prompt scoped to one slice of the docs.

Prompts should ask the subagent to:

- Read the docs the subskill just wrote
- List every place that is unclear, underspecified, internally contradictory, or contains a design flaw / unaddressed gap
- For each finding: cite the file + section, state the issue in one sentence, propose the question that needs answering
- Report back as a numbered list under 400 words

Synthesize the three reports, deduplicate, then present the consolidated findings to the user. For each finding, decide with the user: (a) re-enter the dialog loop to resolve it, (b) defer it explicitly as a "known unknown" recorded in the doc, or (c) reject the criticism.

Iterate (more dialog → re-write docs → another review pass) until the next review pass has no significant findings OR the user calls it done.

### 4. User signoff gate

Single `AskUserQuestion`: "Sign off on `<domain>` and continue to `<next subskill>`?" with options: continue / one more revision / skip ahead (advance without signoff).

The orchestrator surfaces this gate — subskills return control here.

## What this skill will NOT do

- Drive the dialogs itself — that's each subskill's job. The orchestrator is glue.
- Skip subskills based on heuristics. The user explicitly skips via the signoff gate.
- Write to docs directly. Each subskill owns its files.

## Companion skills

- `base-initialize` — calls this skill from Phase 9 on first project setup.
- `define-product`, `define-architect`, `define-qa`, `define-deploy`, `define-tickets` — the five subskills.
- `tickets` (generated by `define-tickets`) — the runtime ticket-CRUD interface; re-entering `define-tickets` after generation uses this skill to sync new specs into the ticketing system.
- `todo` — the day-to-day workflow that runs *against* the specs + tickets this skill produces.
