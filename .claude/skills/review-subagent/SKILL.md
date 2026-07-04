---
name: review-subagent
description: Spawn a LOCAL review subagent (via the Agent tool) that gets our review-agent instructions and audits a diff/commit read-only — a first-class reviewer alongside the fleet peer. Use when the user says "review this with a subagent", "spawn a sonnet review", "/review-subagent", or picks "subagent" / "both" at a peer-review gate. Model defaults to the current Sonnet, overridable via --model or the WORKFLOW_SUBAGENT_REVIEW_MODEL config.
---

# review-subagent — local review subagent

Spawn a **local Agent** that receives our **review-role instructions** and audits a diff/commit **read-only**, reporting GREEN or findings — the same audit a fleet `review` peer runs, but as a self-contained subagent (no dependency on a live peer). It is the "subagent" / "both" arm of the peer-review gate (see [feature.md](../../agent-roles/feature.md)).

## When to Use

- A peer-review gate resolved to **subagent** or **both** (the `AskUserQuestion` "Reviewers" prompt — see the gate contract below).
- The user says "review this with a subagent", "spawn a sonnet review of X", "/review-subagent <target>".

**Do NOT use** for the human-review gate (that's `/monocle-review` / `git diff`) or to *implement* fixes — this is read-only review only.

## Invocation

```
/review-subagent [<target>] [--model <m>] [<ID>]
```

- `<target>` — what to review: a commit (`<sha>`), a range (`<a>..<b>`), `HEAD`, or `working` (uncommitted). **Default:** the in-flight review target — the just-committed change (`HEAD` / the fix commit) or the working-tree diff under review.
- `--model <m>` — model override: `sonnet` | `opus` | `haiku` | `fable`.
- `<ID>` — the in-flight TODO id, passed to the subagent as context.

## Model resolution (in order)

1. `--model <m>` if given.
2. else `WORKFLOW_SUBAGENT_REVIEW_MODEL` from `.claude/workflow.config` (`source .claude/scripts/_config.sh`).
3. else **`sonnet`** (the current Sonnet) — the default.

```bash
source "$(git rev-parse --show-toplevel)/.claude/scripts/_config.sh"
MODEL="${ARG_MODEL:-${WORKFLOW_SUBAGENT_REVIEW_MODEL:-sonnet}}"
```

## Procedure

1. **Resolve** `MODEL` (above) and `TARGET` (the arg, else the review target — usually the latest commit(s) on this branch since the base, or the working tree). Capture the concrete diff command the subagent will run (`git show <sha>` / `git diff <range>` / `git diff` for working tree).
2. **Spawn ONE Agent** (`Agent` tool) with:
   - `subagent_type: general-purpose`, `model: <MODEL>`, `run_in_background: true` (background so it runs in parallel with a peer send when the gate chose "both"; the completion notification carries the verdict).
   - `description`: `Review <ID or target>`.
   - `prompt`: the **reviewer prompt** below, with `<TARGET>`, the diff command, and `<ID>` filled in.
3. **On "both"**, this skill is dispatched **at the same time** as the peer `agent-send` — issue both before awaiting either (see the gate contract). Collect the subagent verdict from its completion notification; collect the peer verdict from the mailbox.
4. **Relay** the subagent's verdict (GREEN / findings) to the user; on findings, fix → re-review (re-spawn against the new commit).

### Reviewer prompt (the instructions the subagent gets)

> You are a **review-role agent** in this fleet, running a **read-only diff audit**. Repo root: `<repo root>`.
>
> **Task:** audit **`<TARGET>`** (`<diff command>`). Report findings only — do **not** modify, commit, or push anything.
>
> **Load the real methodology first:** read and FOLLOW `.claude/agent-roles/review.md` and `.claude/skills/base-pr/SKILL.md` (the audit-dimension sections: design / security / doc-drift / integration-contracts C-13 / nemesis). If the diff touches a **high-risk surface** (money-movement, onchain/contracts, auth/approval, migrations, secrets), run the **full security pass AND the nemesis deep-audit** — do not do a light read.
>
> **Capture the diff read-only** with the command above; read the doc corpus the audit checks against (`CLAUDE.md` + relevant `*/CLAUDE.md`, `docs/security/*`, `docs/integration-notes.md`, best-practices) and verify every claim against the actual code before asserting it.
>
> **Context:** the in-flight TODO is `<ID>` (`docs/todos/<ID>.md` + its `plan:`), if given.
>
> **Output (your final message = the deliverable):**
> - Upfront: "Reviewing `<TARGET>` — N files."
> - Findings by dimension, each `file:line` + a one-line explanation, categorized 🔴 blocker · 🟠 fix-before-merge · 🟡 nit. Refuting a non-issue with evidence is a valid outcome.
> - Whether the **nemesis** deep-audit ran and what it surfaced.
> - **Overall: GREEN LIGHT** (no blockers / fix-before-merge) or **NOT GREEN** with the blocker count.
> - Be skeptical and specific.

## Gate contract (peer-review selection)

At a **peer-review gate**, when the user hasn't already named the reviewers, the gate asks via the **`AskUserQuestion`** tool (header **"Reviewers"**), NOT a printed text menu:

- **1) Both** — fleet peer **and** this subagent, **dispatched at the same time** (issue the peer `agent-send` and this `/review-subagent` before awaiting either), then collect both; proceed only when **both** are GREEN.
- **2) Only peer** — the fleet `review`-role agent (`agent-send` / `base-pr`).
- **3) Only subagent** — this skill alone.

If the user already specified the reviewers (a named peer, "+ a sonnet subagent", a flag), **skip the ask** and honor it. **Under `/afk`** (no human), the default is **Both** (no prompt).

## Companion

- **`agent-roles/review.md`** / **`base-pr`** — the reviewer instructions the subagent loads (single source; this skill doesn't duplicate them).
- **`feature.md`** — the peer-review gate that offers Both/Peer/Subagent.
- **`monocle-review`** — the *human*-review gate (separate from this peer-corroboration step).

---

**Skill Version**: 1.0.0
**Category**: Workflow, Review
