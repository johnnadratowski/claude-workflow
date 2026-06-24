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
/monocle-review [<context>] [<ID>]
```

- `<context>` ∈ `plan` | `todo` | `diff` (default: infer from the in-flight work —
  `plan` at a plan-review step, else `diff`/`todo`).
- `<ID>` — the TODO id (default: the in-flight TODO).

## Procedure

1. **Detect** — `.claude/scripts/monocle-review.sh available`. Exit 2 ⇒ engine down:
   say so, fall back to `git diff` / peer review, stop.
2. **Preview** — `monocle-review.sh list <context> <ID>` shows exactly which
   artifacts will be sent (path + stable id). Skip-warnings (e.g. a TODO with no
   plan) are surfaced, not fatal.
3. **Ask the user** — "Send to Monocle? The diff is reviewed natively; I'll attach
   for context: \<list>." Opt-in **per review** — never auto-send.
4. **Send** — on yes: `monocle-review.sh send <context> <ID>`. Stable ids
   (`plan:<ID>`, `todo:<ID>`) ⇒ each artifact updates in place across every round
   (plan-review now, diff-review later) — one current plan + one current TODO, never
   `v1/v2/v3`.
5. **Wait for the verdict** — block via the normal Monocle path (so a long human
   review doesn't hit a Bash-tool timeout): the MCP `get_feedback` tool with
   `wait=true` (or `/get-feedback-wait`, or the `on-stop` hook). Act on the
   feedback; for change requests, fix → re-send (step 4 updates in place) → re-wait
   until approved.

## Contract for the gates (one-line hook)

A review gate adds, behind the detection guard:

> If Monocle is live (`monocle-review.sh available`), offer `/monocle-review` —
> send the context artifacts and block on `get_feedback`. Otherwise review via
> `git diff` / peer review as before.

The gate's existing behavior is unchanged when the engine is down.

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

**Skill Version**: 1.0.0
**Category**: Workflow, Review

## Changelog

- **1.0.0** — Initial (DX-jn-8-017): detection-gated, TODO-context-aware Monocle
  send with stable per-role artifact ids (update-in-place, anti-clutter); diff left
  to native review; verdict wait via the existing MCP/hook path.
