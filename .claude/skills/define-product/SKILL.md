---
name: define-product
description: Interactive product definition. Drills with the user on what the product does, for whom, and what it must do specifically — deliberately avoiding technology questions. Writes `docs/product.md` (plus split docs when sections grow), then numbered feature specs in `docs/specs/NNN-*.md`, each with a placeholder for tickets to be linked back later. Spawns subagent critics. Detects re-entry and routes to update mode. Owned by the `define-project` orchestrator.
---

# define-product — what the product does, in detail

Run an interactive dialog with the user to specify what the product is and what it must do. **No technology questions** — that's `define-architect`. Your role here is product manager + critical reviewer.

Produces:

- `docs/product.md` — high-level definition + links to split docs and to specs
- `docs/product/<topic>.md` — split docs when `product.md` gets unwieldy (optional)
- `docs/specs/NNN-<slug>.md` — one file per feature spec, NNN zero-padded to 3 digits (`001-`, `002-`, ...)

## Re-entry detection

```bash
if [ -f docs/product.md ] && ! head -1 docs/product.md | grep -qE '^#\s*Product\s*$'; then
  mode="update"
else
  mode="first-run"
fi
```

In `update` mode, ask "what do you want to change?" via `AskUserQuestion` (options: introduction, specific feature, add a new feature/spec, restructure, other). Then enter the relevant part of the dialog instead of starting from scratch.

## First-run dialog

### Phase A: high-level introduction

Ask one open-ended question:

> "Give me a high-level introduction to what you want to build. What is it, who's it for, and what's the *one* problem it solves better than anything else they could use?"

Free-form reply. From it, draft the opening sections of `docs/product.md`:

- `# Product` heading (this is the marker that signals "fully filled in" — keep the literal string but add content underneath)
- `## In one sentence` — your distilled version, shown to user for confirmation
- `## Who it's for` — the target user(s)
- `## The problem` — the gap it fills

Confirm each section with the user before continuing. If anything in the user's reply is vague (e.g., "small businesses" — which kind? what size?), challenge it before writing it down.

### Phase B: drill loop

After the intro is locked, loop. Each turn:

1. Look at what's been written so far. Pick the **single most underspecified area** — the one a developer reading the doc would have the most questions about.
2. Ask 2–4 targeted questions about that area via `AskUserQuestion`. Mix multi-choice and free-form-with-AskUserQuestion-as-"Other".
3. Update `docs/product.md` (or a split doc) with the new content. Show the diff to the user.
4. Ask: "Continue with more questions, or are you done?"

Examples of "drill" subjects to walk through over the loop, ordered roughly coarsest to finest:

- Core user journeys (numbered, each one a sentence)
- The handful of "must-work" scenarios — the ones that, if broken, make the product worthless
- Edge cases the user has thought about (and the ones they haven't — propose them)
- Non-functional requirements that are user-visible (latency budget, offline behavior, data retention, deletion semantics — but only as the user *perceives* them, not how they're implemented)
- Failure modes the user is OK with vs not OK with
- What the product explicitly does NOT do (this is load-bearing; revisit it whenever scope creeps)

### Your role: critical reviewer

For every user answer, before you write it down, ask yourself:

- **Is it ambiguous?** "Fast" / "reliable" / "easy" / "professional" — push back. What does that mean *in observable behavior*?
- **Is it self-contradictory** with something the user already said? Surface the conflict.
- **Is there an obvious failure mode** the user hasn't mentioned? Raise it: "What should happen if X?"
- **Are you about to commit a design decision the user hasn't made?** Stop. Ask.
- **Is the user telling you HOW instead of WHAT?** Redirect — "we'll cover the how in the next stage; for now, what's the user-visible behavior?"

Don't write the answer down until it passes these checks.

### Suggestions you should proactively make

Don't be a stenographer. While drilling, also propose:

- Features the user hasn't mentioned but a product like this typically has (e.g., for a SaaS — onboarding flow, account deletion, export, audit log)
- Failure modes that need a defined behavior (e.g., what happens when the user goes offline mid-action?)
- Conflicts with their stated principles (e.g., "you said data privacy is a top priority, but you also want analytics — let's spec exactly what's tracked")

Frame as suggestions, not demands. The user can dismiss.

## Phase C: splitting product.md

If `docs/product.md` grows beyond ~500 lines or covers loosely-coupled topics, split:

```
docs/product.md                 # short intro + table of contents linking to:
docs/product/user-journeys.md
docs/product/non-functional.md
docs/product/out-of-scope.md
... etc.
```

The split boundary is a natural concern boundary, not a line count. Don't split prematurely.

## Phase D: specs

Once the product definition feels solid, transition to **specs**: numbered, granular feature descriptions that will become tickets.

```
docs/specs/001-user-signup.md
docs/specs/002-task-creation.md
docs/specs/003-task-archive.md
...
```

Each spec file uses this template (write it literally):

```markdown
# Spec NNN: <Title>

## Summary
<one paragraph>

## User-visible behavior
<numbered list of observable behaviors, each unambiguous>

## Acceptance criteria
- [ ] <one testable criterion per line>
- [ ] ...

## Out of scope for this spec
- ...

## Open questions
- ...

## Related specs
- Spec NNN: <title> — <relationship>

## Tickets

<!-- This section is filled in by define-tickets after ticket creation. -->
<!-- Format: one bullet per ticket: `- [PROJ-123](url) — <title>` -->

_No tickets created yet._
```

**The `## Tickets` section is mandatory and load-bearing** — `define-tickets` finds specs by scanning for it. Don't omit it. Don't rename it.

### How to extract specs from the product doc

Walk every numbered user journey and every "must-work" scenario in `docs/product.md`. For each one, draft one or more specs. Show the user the draft list ("here are the 12 specs I extracted; review the titles and let me know what's missing / wrong / should be merged / should be split").

Iterate until the user signs off on the spec list, then write each spec file. Walk each spec with the user — 2-4 questions per spec to fill in acceptance criteria + open questions + out-of-scope.

When `docs/product.md` is updated later (re-entry mode), specs may need to be added / split / merged. Renumbering breaks ticket links, so **never renumber an existing spec**. Add new specs at the next available number. If a spec is obsolete, mark it `## Status: obsolete` at the top and leave the file.

## Phase E: subagent critical review

After the user signs off on the dialog + specs:

Spawn **3 subagents in parallel** via the Agent tool (single message, three Agent calls, `subagent_type: general-purpose`):

1. **Product critic** — read `docs/product.md` + any `docs/product/*.md`. List unclear / ambiguous / contradictory statements. Propose questions to resolve each. Cap at 400 words.
2. **Spec coverage critic** — read `docs/product.md` + `docs/specs/*.md`. Identify behaviors in the product doc that have no spec, specs that overlap / conflict, and acceptance criteria that aren't testable. 400 words.
3. **Failure-mode critic** — read everything. List user-visible failure scenarios that have no defined behavior. 400 words.

Synthesize the three reports — deduplicate, group by file, sort by severity. Present to the user as a consolidated list. For each finding, decide with the user: (a) drill back into dialog, (b) record as `## Open questions` in the relevant doc, (c) reject.

Loop: more dialog → re-write docs → another review pass → present new findings. Done when the next pass produces no new significant findings OR the user calls it done.

## Phase F: signoff

`AskUserQuestion`:

- **Sign off and continue to `define-architect`** (recommended once review is clean)
- **One more dialog pass** (loops back to Phase B)
- **One more review pass** (re-runs Phase E)

Return control to `define-project`.

## Update mode (re-entry)

When `mode="update"`, instead of running Phase A → F linearly:

1. Ask "what do you want to change?" (intro / specific feature / add new feature / restructure / other)
2. Jump into the relevant phase
3. Always end with Phase E (subagent review of the *changed* docs only) + Phase F (signoff)

Existing specs are **never renumbered** in update mode. New specs are appended at the next number.

## What this skill will NOT do

- Ask about technology, libraries, frameworks, or implementation. That's `define-architect`.
- Write code. Specs are documentation only.
- Skip the subagent review unless the user explicitly waives it.
- Rename or renumber existing specs.

## Companion skills

- `define-project` — the orchestrator that calls this.
- `define-architect` — the next stage.
- `define-tickets` — uses the `## Tickets` section in each spec to track ticketing-system IDs.
