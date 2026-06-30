# monocle-review — opt-in Monocle review at the user-review gates

Offer to send a review to Monocle **when (and only when) the Monocle engine is live
for this repo**, attaching the context that isn't in the diff (the in-flight TODO +
its plan) as artifacts under **stable ids** so re-sends update in place instead of
accumulating. Backed by `.claude/scripts/monocle-review.sh` + the declarative
`.claude/monocle-artifacts.json`.

This skill does not replace the human-in-the-loop review gate — it's the
**Monocle-flavored option** of it. The diff is reviewed by Monocle **natively**
(working tree, rendered properly); this skill adds the surrounding context and the
verdict round-trip.

> **Sending to Monocle is BLOCKING by default — you send AND wait for the verdict, then
> act on it.** Never fire-and-forget: after sending (+ grouping/annotating) you MUST
> block on `get_feedback` (wait=true) until the reviewer submits, then handle the
> feedback (approve → proceed; changes → fix, re-send, re-wait). This is the default at
> every call site (the `/todo` gates, `pr-comments`, ad-hoc "send this to monocle").
> **Fire-and-forget is opt-in only** — do it solely when the user explicitly says so
> (e.g. "just send it, don't wait"). A review you sent but didn't wait on is not a
> review — it's an ignored request.

## When to Use

- A workflow review gate is offering Monocle: the `/todo` **plan-review** step, the
  **user-review-before-commit** gate (coordinator / feature flow), or `base-pr`'s
  review point.
- The user says "send this to monocle", "review this in monocle", "send the plan to
  monocle".

**Do NOT use** when the engine is down — fall back to `git diff` / peer review (the
script tells you: `available` exits 2). And do NOT route the **diff** through it —
Monocle reviews the working-tree diff natively and renders artifacts raw; this skill
only sends **context** (TODO + plan).

## Invocation

```
/monocle-review [<context>] [<ID> …]
```

- `<context>` ∈ `plan` | `todo` | `diff` (default: infer from the in-flight work —
  `plan` at a plan-review step, else `diff`/`todo`).
- `<ID> …` — the TODO id(s) (default: the in-flight TODO). A `diff` review may name
  **multiple** TODOs when the working tree holds more than one workstream — each gets
  its artifacts sent and becomes a top-level workstream group (step 5).

## Procedure

1. **Detect** — `.claude/scripts/monocle-review.sh available`. Exit 2 ⇒ engine down:
   say so, fall back to `git diff` / peer review, stop.
2. **Preview** — `monocle-review.sh list <context> <ID>` shows exactly which
   artifacts will be sent (path + stable id). Skip-warnings (e.g. a TODO with no
   plan) are surfaced, not fatal.
3. **Ask the user** — "Send to Monocle? The diff is reviewed natively; I'll attach
   for context: \<list>." Opt-in **per review** — never auto-send.
4. **Send + name the review** — on yes: `monocle-review.sh send <context> <ID>` (run
   it once per `<ID>` when the diff spans multiple TODOs — each call adds that TODO's
   `plan:<ID>` + `todo:<ID>` artifacts). Stable ids ⇒ each artifact updates in place
   across every round (plan-review now, diff-review later) — one current plan + one
   current TODO each, never `v1/v2/v3`.
   **Name the review** via the MCP `set_review_name({name})` tool (shows in Monocle's
   top bar; call it once when the review starts — it is NOT the artifact titles, which
   name individual context docs). A **single-TODO** review is named for that TODO (its
   id, e.g. `DX-jn-8-022`, optionally `<ID> — <title>`); a **multi-TODO** review gets a
   short descriptive name *or* the TODO ids joined (`DX-jn-8-022 + DX-jn-8-023`).

   **Already-committed work — set a base ref (do this BEFORE step 5).** The default
   review is the working-tree diff (uncommitted) — the normal flow reviews *before*
   committing (the `/todo` step-7 gate is pre-commit). But when the work is **already
   committed** (a committed fix round, a re-review of landed work, a peer's branch, or a
   full branch-vs-base review), the working-tree diff is empty, so call the MCP
   **`set_base_ref({ref})`** tool with the commit to diff against — the branch you
   started from, a SHA, or `HEAD~N`. Monocle then reviews everything since `<ref>` (your
   commits included) with the **full native surface** (grouping, annotations, proper
   rendering). It auto-reverts to working-tree mode once the reviewer submits, or
   `set_base_ref({reset: true})` to revert now. **Pass the SAME `<ref>` to
   `monocle-review.sh groups <ref>`** in step 5. **Anti-pattern: never send the diff as a
   raw artifact** — Monocle renders artifacts raw, losing grouping/annotations/the gutter;
   `set_base_ref` is the right tool.
5. **Group the changed files (diff context only) — ALWAYS.** Organize the changed files
   so the reviewer reads them as a story, via the MCP `set_file_groups` tool
   (`replace=true`; reviewer presses `f` to cycle to the grouped view). Monocle supports
   **N nesting levels**; we use up to two, the top one optional:
   - **Category level (always).** Run `monocle-review.sh groups` (or
     **`monocle-review.sh groups <base>`** for a committed / base-ref review — the same
     `<ref>` you passed to `set_base_ref`) — it classifies the
     diff **deterministically** into the canonical bottom-up order **infra → contracts
     → subgraph → db → types → api → sdk → ui → docs → tests** (substrate → surface),
     call-hierarchy-sorted within each. This is the categorization we've always used;
     being script-derived, every agent (author OR a peer) groups identically.
   - **Workstream level (top — ONLY when the diff spans >1 TODO).** With multiple TODOs
     under review, wrap each file's category under its **TODO id** as the top level
     (`workstream → category`), ordered by TODO. The **author supplies** this split —
     only the author knows which uncommitted file belongs to which TODO; it is NOT
     script-derivable pre-commit (no `commits:` ledger yet). **A single-TODO review has
     NO workstream level** — just the one category level, exactly as before.
   - **Collapse singletons** — don't emit a level whose only child is a single file (a
     1-file "api" subgroup is noise); render the file directly.
   - `criticality` is a separate float-within axis — bump a higher-risk file with
     `"criticality": <n>`. New files only group if Monocle's native diff sees them —
     `git add` (stage) any untracked changed files first. (Plan/todo-only contexts have
     no diff — skip this step.)
6. **Annotate the non-obvious ranges (diff context only) — author-only.** After
   grouping, attach short one-line rationale notes to the changed ranges via the MCP
   `add_annotations` tool, so the reviewer sees *what each range does* with a
   click-through to the doc that explains *why*. These are a write-only reviewer aid
   (never returned as feedback) — generated by the **authoring agent** (semantic, not
   script-derived like grouping, so a peer-sent review won't reproduce them).
   - **Selective, not exhaustive.** Annotate only ranges where the *why* is
     non-obvious; skip self-explanatory code (C-7). **Prefer** ranges whose rationale
     you encoded in a doc during doc-sync (C-12/C-13) — `product.md` / a topic doc /
     `integration-notes.md` / `architecture.md` / the plan / the TODO.
   - **Entry shape — bound the EXACT code the note explains.**
     `{file (a changed file), line_start, line_end, summary (one line), refs[]}`.
     `line_start`/`line_end` must tightly bracket the specific changed lines the note
     is about (new-file line numbers, 1-based, read straight from the diff you're
     reading) — **not** the whole file, **not** an approximate span: Monocle draws a
     gutter bar over exactly that range, so a sloppy range mislabels unrelated code.
     Single-line note ⇒ `line_start == line_end`. Each ref is
     `{kind: 'file'|'artifact', doc, label, start_line, start_col, end_line, end_col}`
     (doc lines 1-based, cols 0-based) pointing at the passage — `kind:'file'` → a repo
     doc at its **post-edit** line range; `kind:'artifact'` → a `plan:<ID>` /
     `todo:<ID>` artifact already sent in step 4. **Summary-only is allowed** (a ref is
     preferred, not required).
   - **Send with `replace=true`, then read the response.** The tool reports accepted
     vs **rejected entries (with reasons)** and **warnings for refs that don't
     resolve** — fix those and resend until clean (the channel validates upstream; it
     will not silently swallow a bad range/ref).
   - **Rounds:** a fix re-sent *within* a round repeats this step with `replace=true`
     (annotations are line-static — no in-round auto-rebase). *Across* rounds the
     reviewer submitting **auto-clears** them, so just re-annotate against the new code.
   - (Plan/todo-only contexts have no diff — skip this step.)
7. **Report the review stats — ALWAYS, right after staging.** Once the review is sent
   (+ grouped/annotated for a diff), emit a one-block summary so the user sees exactly
   what was staged before the verdict wait:
   - **Review name** — the `set_review_name` value
   - **Base ref** — the `set_base_ref` ref, or `working tree (HEAD)` when none
   - **Files in review** — count of changed files (the `set_file_groups` entries; `0`/n-a for a plan/todo-only context)
   - **Context artifacts** — count sent (`plan:`/`todo:` pairs)
   - **Additional files** — count added via the `add_files` tool (extra context beyond the diff; `0` if none)
   - **TODOs** — the `<ID>`(s) included in the review

   ```
   📋 Monocle review staged — "DX-jn-8-022 + DX-jn-8-023 · review-skill dogfood"
      base ref: working tree (HEAD) · files: 9 · artifacts: 4 · added files: 0 · TODOs: DX-jn-8-022, DX-jn-8-023
   ```
8. **Wait for the verdict — MANDATORY (the blocking default; never skip).** After
   sending, block via the normal Monocle path (so a long human review doesn't hit a
   Bash-tool timeout): the MCP `get_feedback` tool with `wait=true` (or
   `/get-feedback-wait`, or the `on-stop` hook). Do not move on to other work / end the
   turn while a sent review is unanswered — you sent it, you wait for it. Act on the
   feedback; for change requests, fix → re-send (step 4 updates in place; re-run step 5
   if the file set changed; re-run step 6 to re-annotate the new code) → re-wait until
   approved. (Only skip the wait if the user explicitly asked for fire-and-forget.)

## Contract for the gates (the 3-option review-path prompt)

At a review gate — the `/todo` **plan** gate and the **implementation/diff** gate — the
agent presents the user a **3-option prompt**:

> **1) Send to Monocle** — `/monocle-review <plan|diff> <ID>` (this skill: sends the
> context artifacts, groups + annotates a diff, blocks on `get_feedback`). Offered
> **only when the engine is live** (`monocle-review.sh available`).
> **2) Send to peer review** — a live `review`-role agent (`agent-send` / `base-pr`).
> **3) Skip review → implementation/commit.**

Monocle is **option 1**; when the engine is down it's omitted and the user picks peer or
skip. **Under `/afk` the prompt is not shown — default to peer review.** (Full gate wiring:
the `/todo` skill's plan gate + step 7.)

## Declarative artifact set

`.claude/monocle-artifacts.json` maps **roles** (path + stable id + syntax type) to
**contexts** (which roles to send). Adding "also always send X" is a one-line data
edit there — no script or skill change.

## Caveat

Monocle renders artifact markdown/diffs **raw** (no pretty render). Fine for context
files (TODO, plan read fine raw); it's the reason the diff is left to native review
rather than sent as an artifact.

## Companion

- **`/review-plan` / `/review-plan-wait` / `/get-feedback` / `/get-feedback-wait`** —
  the lower-level MCP commands; this skill is the TODO-context-aware, detection-gated
  layer on top.
- **`/todo`**, **`base-pr`** — the gates that call into this skill.

---

**Skill Version**: 1.7.0
**Category**: Workflow, Review
_Version history: see [CHANGELOG.md](./CHANGELOG.md)._
