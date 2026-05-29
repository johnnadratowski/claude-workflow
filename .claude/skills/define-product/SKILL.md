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

### Phase B: drill loop — two-level control

The user controls **how deep** to go on each area AND **which areas** to cover. The loop has two nested levels:

**Inner loop — depth on a single area.** Pick an area. Drill into it with `AskUserQuestion` (2–4 questions per turn). Update the docs. Ask: "Want to go deeper here, or have we covered this enough?" If "deeper", surface the most underspecified follow-up and continue. If "enough", exit the inner loop.

**Outer loop — area coverage.** Once an area is "enough", surface the next area. Two ways to pick it:
1. **Suggest one** — pick from the area list below based on what's least defined relative to the product so far, framed as a recommendation.
2. **Let the user choose** — show the area list (collapsed to category headings, not every sub-bullet) and ask via `AskUserQuestion` which to tackle next.

After each area, the user can say "I want to move on" to exit the outer loop and proceed to Phase C/D. **Areas not covered are not failures** — record them as `## Open questions` entries (one bullet per skipped area, naming the area) in `docs/product.md` so a future `/define-product` re-entry surfaces them as natural starting points.

The whole skill exits when the user says "done overall" (or equivalent). If they've only covered the intro from Phase A and one area, that's fine — they can re-enter later with more information.

### What you should never do in this skill

- Ask anything about **technology choices** — frameworks, languages, libraries, hosting, databases, storage formats, performance optimization techniques. Redirect every such answer: "we'll cover that in the architect stage; for now, what's the user-visible behavior?"
- Force coverage of areas the user isn't ready for. Park them as `## Open questions` and move on.
- Treat the area list as a checklist. It's a menu; the user orders from it.

### Your role: critical reviewer

For every user answer, before you write it down, ask yourself:

- **Is it ambiguous?** "Fast" / "reliable" / "easy" / "professional" — push back. What does that mean *in observable behavior*?
- **Is it self-contradictory** with something the user already said? Surface the conflict.
- **Is there an obvious failure mode** the user hasn't mentioned? Raise it: "What should happen if X?"
- **Are you about to commit a design decision the user hasn't made?** Stop. Ask.
- **Is the user telling you HOW instead of WHAT?** Redirect — "we'll cover the how in the next stage; for now, what's the user-visible behavior?"

Don't write the answer down until it passes these checks.

### Be proactive — don't just be a stenographer

While drilling, also propose:

- Features the user hasn't mentioned but a product like this typically has (e.g., for a SaaS — onboarding flow, account deletion, export, audit log)
- Failure modes that need a defined behavior (e.g., what happens when the user goes offline mid-action?)
- Conflicts with their stated principles (e.g., "you said data privacy is a top priority, but you also want analytics — let's spec exactly what's tracked")

Frame as suggestions, not demands. The user can dismiss.

### The area list

**★** marks the **essentials** — areas that are load-bearing for almost any product; aim to at least *surface* these even if the user defers a deep dive. **§** marks **business-scope** areas — they look optional but often quietly determine what gets built and what doesn't; raise them early so they're not retrofitted.

Areas tagged `(originally covered)` were the only ones the prior version of this skill named; the rest are new. Everything here is asked at the **user-visible-behavior** level — never at the implementation level.

#### Users — who specifically

- **★ Personas** — the *specific* user, not "small businesses". Roles? Power vs casual? Multiple user types with different needs?
- **Existing alternatives** — what are they using today, and what's wrong with it? Tells you the migration story + the differentiation bar.
- **Anti-personas** — who is this *not* for? Useful for scope discipline.

#### First touch + return

- **★ Onboarding / first-run** — what does minute 1 look like? Account required? Sample data? Tutorial vs throw-them-in?
- **★ Empty states** — what does the product look like with zero data in it? Major UX cliff if left undefined.
- **Cold start vs returning user** — first-time vs someone who's been gone 6 months; different experiences?

#### Object model — the nouns of the product

- **★ First-class objects** — what are the things the user creates / owns / acts on? Each one probably becomes its own spec. (Originally covered as "user journeys", but the noun-list is often the better starting point.)
- **★ Data lifecycle** — create → update → archive → delete. Soft vs hard delete? Retention windows?
- **Versioning / history** — does the user expect to see "what did this look like yesterday?"
- **★ Undo + safety nets** — destructive actions: undo window? Confirmation? Trash bin?

#### Multi-user dynamics

- **★ Permissions** — who can see / edit / share / delete what. Role-based? Per-resource?
- **Sharing / collaboration** — solo product, or do users invite others? Sync (real-time) vs async (comments, mentions)?
- **Multi-tenancy** — workspaces / orgs / teams? Cross-tenant boundaries?
- **Audit / accountability** — does the user need to see "who changed this and when"?

#### Operations at scale

- **Search / discovery** — how does the user find a thing when they have lots of them?
- **Bulk operations** — they'll inevitably want to act on many at once; what's in / out of scope?
- **Quotas + limits** — per-user / per-team caps on storage, items, API calls
- **★ Defaults** — when the user doesn't configure something, what happens? (A product decision people forget is one.)

#### Reach + interop

- **Form factor(s)** — web / mobile / desktop / CLI / API. Same features per platform, or different?
- **★ Notifications** — when does the product proactively reach out? Email / push / in-app / none?
- **★ Integrations** — what other products does this read from / write to? OAuth providers? Webhooks?
- **Import / migration** — coming from a competitor, how does their data get in?
- **Export / portability** — can the user get their data *out*, and in what format?

#### Cross-cutting non-functional (user-visible only)

- **Accessibility** — target conformance level, keyboard nav, screen reader scope
- **Localization** — languages, date / currency formats, RTL
- **Time** — does the product care about time zones / recurrence / scheduling?
- **Offline behavior** — what works without a network, what doesn't, what does the user *see* (originally covered as part of NFRs)
- **Latency / responsiveness** — what's the user-visible perception target, NOT the implementation budget (originally covered)

#### Business + scope (often skipped, often important — §)

- **§ Business model** — free / trial / paid / per-seat / usage. Drives gating + rate-limit decisions.
- **§ The 60-second demo** — the *one* thing you'd show to convince someone. Forces clarity on the core value.
- **§ Time horizon** — MVP-in-90-days vs platform-for-5-years. Ruthlessly clarifies scope.
- **§ Success criteria** — how will the *user* know they got value? How will the *team* know it worked?
- **§ Anti-features** — things you explicitly will not build, even if asked. Most product docs are missing this section.
- **★ "Must-work" scenarios** — the handful that, if broken, make the product worthless (originally covered)
- **★ Out of scope** — what the product explicitly does NOT do; revisit whenever scope creeps (originally covered)

#### Failure + edge

- **★ Failure modes** — what the user is OK with vs not OK with when things go wrong (originally covered)
- **Edge cases** — the ones the user has thought about, and the ones they haven't (propose them) (originally covered)

### How to surface the list to the user

Don't dump the whole tree at once. When asking the user "which area next?":

1. If you have a strong recommendation (essentials they haven't touched), lead with: "I'd suggest <area> next — <one-sentence why>."
2. Show the **category headings** as `AskUserQuestion` options plus an "Other" / free-form fallback. Once they pick a category, list the bullets *inside* that category for the next selection (or just pick the most essential one inside it and ask if they want that or something else).
3. Always offer "I'm done overall" as an option in the outer loop.

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

1. **Scan `docs/product.md` (and any split docs) for `## Open questions`** — every bullet there is an area the user previously deferred. Surface these *first* as natural starting points: "Last time you parked these — want to tackle any now? <list>". They map directly back to the Phase B area list.
2. If none are pending, ask the broader "what do you want to change?" (intro / a specific area from Phase B's list / a specific spec / add new feature / restructure / other).
3. Jump into the relevant phase. For an area drill, re-enter Phase B's two-level loop scoped to that one area.
4. Always end with Phase E (subagent review of the *changed* docs only) + Phase F (signoff).

Existing specs are **never renumbered** in update mode. New specs are appended at the next number.

This re-entry behavior is why Phase B records skipped areas as `## Open questions` instead of leaving them unmentioned — they become the breadcrumb trail for the next session.

## What this skill will NOT do

- Ask about technology, libraries, frameworks, or implementation. That's `define-architect`.
- Write code. Specs are documentation only.
- Skip the subagent review unless the user explicitly waives it.
- Rename or renumber existing specs.

## Companion skills

- `define-project` — the orchestrator that calls this.
- `define-architect` — the next stage.
- `define-tickets` — uses the `## Tickets` section in each spec to track ticketing-system IDs.
