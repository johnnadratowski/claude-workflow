---
name: pr-comments
description: Methodically service a GitHub PR's review round — complete comment inventory across all three surfaces, critical investigation of every claim before any disposition (refuting wrong feedback with evidence is a first-class outcome), clustered triage with the user while reply drafts accumulate UNPOSTED, implementation through the internal review flow with TODO ledger linkage, a reviewer-subagent package-audit near the end, and atomic posting only on the user's final approval. Use when the user says "go through the PR comments", "service the review feedback", "address the comments on PR <n>".
---

# pr-comments — service a PR review round, methodically

Work through every comment on a PR with full inventory, critical verification, user-in-the-loop triage, and **nothing posted to GitHub until the user's final approval**. One invocation = one review round, ending in one atomic posting pass.

## When to Use

- "Go through the comments on PR 52" / "we got review feedback, address it".
- A reviewer finished a round on a PR opened via `/open-pr` (or any PR).

**Do NOT use** for opening PRs (`/open-pr`) or for internal fleet review (`/base-pr`, `agent-send`).

## Invocation

```
/pr-comments <n> [--dry-run] [--no-resolve] [--reply-only]
```

- `--dry-run` — phases 1–3 only (inventory + investigation + triage proposal); nothing implemented, nothing posted.
- `--no-resolve` — post replies but never resolve any thread (leave all to the human). Overrides the phase-1 reviewer question. **If both `--no-resolve` and `--resolve` are passed, `--no-resolve` wins** (most conservative).
- `--resolve` — resolve every addressed thread wholesale. Overrides the phase-1 reviewer question (use for autonomous/agent-only PRs).
- `--reply-only` — no code changes expected (e.g. answering questions); skips phases 4–5.

> **Agent-authored marker (two parts — visible head + invisible tail).** Every
> reply/comment this skill posts is sandwiched between two author signals:
>
> 1. **Visible head — human transparency.** The body STARTS with a bold tag on its
>    own line so a human scrolling the PR sees at a glance it came from an agent. Get
>    it from `.claude/scripts/agent-identity.sh tag` and prepend it verbatim (followed
>    by a blank line):
>    ```
>    **[AGENT RESPONSE · <name> / <role>]**      ← registered fleet agent
>    **[AGENT RESPONSE]**                          ← identity unresolvable (fallback)
>    ```
> 2. **Invisible tail — machine classification.** The body ENDS with a
>    human-invisible, regex-detectable marker:
>    ```
>    <!-- agent-authored:pr-comments -->
>    ```
>    It renders as nothing in GitHub markdown but is regex-detectable when a later
>    round re-reads thread bodies. It is what lets the resolution logic (phase 7)
>    tell agent- from human-authored comments.
>
> The two serve different audiences — the visible head for humans, the invisible tail
> for the classifier — so keep BOTH; the head is not a substitute for the marker, and
> the marker is **not** the resume authority (the round journal is — see Resumable).
> `/open-pr`'s posted comments carry both too.

## Phases

### 1. Fetch + inventory — ALL three surfaces, paginated

A PR's feedback lives on three distinct API surfaces; missing one means silently dropped comments:

```bash
gh api --paginate "repos/{owner}/{repo}/pulls/<n>/comments"   # inline review comments (thread anchors: file/line)
gh api --paginate "repos/{owner}/{repo}/pulls/<n>/reviews"    # review summaries + verdicts
gh api --paginate "repos/{owner}/{repo}/issues/<n>/comments"  # top-level conversation comments
```

**`--paginate` on every call** — review rounds on a long-lived PR overflow one page easily. Thread **resolved-state is NOT on the REST surface**; read it via GraphQL (same connection used for resolving in phase 7):

```bash
gh api graphql -f query='query($owner:String!,$repo:String!,$n:Int!){
  repository(owner:$owner,name:$repo){pullRequest(number:$n){
    reviewThreads(first:100){nodes{id isResolved isOutdated path line comments(first:50){nodes{databaseId author{login} body}}}}}}}' \
  -f owner={owner} -f repo={repo} -F n=<n>
```

Build the **checklist** — per thread, capture:
- the **root comment id** (the first node's `databaseId` from the GraphQL `reviewThreads` query) — this is the **reply anchor** phase 7 posts to. Recording it now removes the manual thread→id mapping that's error-prone across a long round.
- `path:line`, author of each comment, and `isResolved` / `isOutdated`.
- **authorship** of each comment — human vs agent-authored (the latter detected by the `agent-authored:` marker in the body). This drives the phase-7 resolution decision.
- an empty **disposition**.

Already-resolved threads are listed (for context) but not serviced. **Every item ends the round with an explicit disposition** — `fixed` / `explained` / `outdated` / `deferred → TODO` / `disagree + rationale`. No silent drops.

**Ask up front: is there a human reviewer?** Before triage, ask whether a human will review/resolve these threads or this is an autonomous (agent-only) PR. The answer sets the phase-7 resolution default (human present → leave their threads for them; no human → resolve wholesale). **If the question is never answered, default to human-present** (conservative — never auto-resolves a human's thread). `--no-resolve` / `--resolve` override it.

### 2. Author awareness — context, not authority

Resolve the user's own GitHub login (`gh api user -q .login`) and attribute their comments as **the user's** in the inventory and triage. This is **identity context, not an authority bypass**: their comments are investigated exactly like any other (phase 3), and if one reads like a request for a specific implementation, **ASK the user whether that's what they want** before building it — don't infer a directive from a comment.

### 3. Investigate before believing

**Every comment is verified against the code/docs/tests BEFORE a disposition is proposed.** Reviewers are sometimes wrong; an agreeable agent that "fixes" a non-issue makes the code worse. Per item, record one of:

- **confirmed** — the claim checks out (cite the evidence).
- **partially right** — what holds, what doesn't.
- **refuted** — a respectful, evidence-backed explanation; refuting wrong feedback is a first-class outcome, not a failure to comply. **For any claim about code/contract/test behavior, QUOTE the actual source** at the cited `file:line` — do not paraphrase it. (Dogfood lesson: the one error the package audit caught was a refutation that *paraphrased* a contract and got the semantics backwards. Quoting the line makes the refutation self-checkable at draft time.)
- **outdated** — the comment is anchored on code that has **since changed**; the live state differs from what the comment assumes. The reply states the current state with quoted `file:line`. Note: GraphQL `isOutdated` (the diff hunk moved) is only a *hint* — a substantively-moot comment may or may not be flagged `isOutdated`, and a moved hunk may still be a live concern. Judge the substance, not the flag.
- **needs-discussion** — genuinely ambiguous or a judgment call → triage with the user.

### 4. Clustered triage with the user — drafts accumulate, NOTHING posts

Group related comments (same file, same theme, same root cause) and discuss each **cluster in one shot** — never march one-by-one through items that share an answer. For each cluster present: the comments, the investigation outcomes, the proposed dispositions, and a **draft reply per thread**. The user adjusts course as you go; drafts evolve alongside.

**The draft artifact must be reviewable standalone.** Write the drafts to a markdown file the user reads, and for **each thread** lay it out so no cross-referencing GitHub is needed:

```
### T<n> — <path>:<line> — <disposition>
> **<author>:** <original comment, quoted>
> **<author>:** <any existing reply, quoted>

Code: <github-blob link …/blob/<sha>/<path>#L<line>>  (+ any other cited file:line links)

<drafted reply>
```

The quoted prior comments + code links as a **preamble** above each drafted reply (dogfood feedback: drafts were hard to review without the thread context in front of you). Keep the per-thread root comment id from phase 1 alongside so phase 7 has its post target.

**Citing a fix — link the diff, not just the hash.** When a reply says you fixed something, keep the commit hash **and add a direct link to that change's diff** so the reviewer can jump straight to the exact change being referenced:

- **commit diff** — `https://github.com/<owner>/<repo>/commit/<sha>` (owner/repo via `gh repo view --json nameWithOwner -q .nameWithOwner`). Shows the full commit diff.
- **LOC-specific** (the comment was about a particular file/line) — anchor to it: `…/commit/<sha>#diff-$(printf '%s' "<path>" | sha256sum | cut -d' ' -f1)R<new-line>` — the `#diff-<sha256(path)>` selects the file and `R<n>` the post-change (right-side) line (`L<n>` for a removed line).

So a fix citation reads like ``fixed in `a1b2c3d` ([diff](…/commit/a1b2c3d#diff-…R42))``. This applies in **both** the draft (so the link is visible in the Monocle review) and the posted reply. The link resolves because phase 7 pushes the `pr/*` head before any reply posts.

**When Monocle is live, present the drafts IN MONOCLE — one artifact per response** (not the single combined file), so the user reviews exactly what will be posted before it posts. For **each** drafted reply send a `send_artifact` (CLI `monocle review send-artifact` or the MCP tool) with:

- **id** — stable per thread: `pr-<n>-reply-<root-comment-id>` (re-sends update in place across rounds, no `v1/v2` clutter).
- **title** — `reply → <author> @ <path>:<line>` (inline) or `reply → <author> (conversation)` (no LOC).
- **content** (md) — **prefaced with the original comment and its LOC**, then the draft:
  ```
  **Original comment** — <author> on `<path>:<line>`   ← omit the `@ path:line` when the comment isn't anchored to a LOC
  > <original comment, quoted>
  > <existing reply, quoted, if any>

  **Draft reply:**
  <the reply exactly as it will post — incl. the [AGENT RESPONSE …] tag + fix-commit hash + its diff link (per "Citing a fix") + `file:line` cite>
  ```

Then **block on the verdict** (the `monocle-review` blocking default — never fire-and-forget); incorporate the user's edits, re-send (stable ids update in place), re-wait until approved. The fix **diff** is reviewed natively alongside (via `set_base_ref` if already committed onto the `pr/*` branch). Engine down ⇒ fall back to the combined markdown file above.

**Hard rule: nothing posts during this phase.** Drafts live locally until phase 7 — Monocle artifacts are for *review*, not posting.

### 5. Implement accepted fixes — internal flow + TODO linkage

Fixes go through the normal internal flow: implement on the working branch, gates, a reviewer-subagent diff review for substantive changes (mode 1 when a TODO scopes the fix, else mode 2), then onto the `pr/*` branch (cherry-pick or re-split, matching how the PR was scoped — and push to the `pr/*` head only as part of phase 7's approved package).

> **If you route any review through Monocle here** (the fix diff, or the phase-6 package audit), it follows the **`monocle-review` blocking default — send AND wait for the verdict** (`get_feedback` wait=true), then act on it. Never fire-and-forget: a Monocle review you sent but didn't wait on is an ignored request. (Fire-and-forget is opt-in only — when the user explicitly says so.) If the fix is already committed onto the `pr/*` branch, review it via `set_base_ref` rather than a raw diff artifact.

**TODO ledger linkage** (the PR's tag block tells you the ID; tag updates go through `/open-pr` step 6 so the implementation stays single):

- **Substantive comments on a completed TODO** → either `/todo reopen <ID>` (optionally for another agent to pick up) or fix directly and UPDATE the completed TODO's body with the findings/changes, appending the fix commits to `commits:`.
- **Findings outside the original scope** → recommend a NEW TODO rather than silently widening this one.
- Deferred items get a real TODO minted (`deferred → TODO` dispositions must reference the minted ID).

### 6. Package audit — peer review of the whole round (near-last)

Bundle = original comments + the implementation diff + every draft reply. Spawn the [`reviewer`](../../agents/reviewer.md) definition in **mode 2 (range/bundle audit)** with the bundle inline to audit **coherence**: do the fixes actually address the comments; do the replies describe the fixes accurately; are the refutations correct; is anything left unanswered? (Same spawn solo or fleet — the reviewer is local, no peers involved; model from `WORKFLOW_REVIEW_MODEL_B` (single-reviewer knob, default `sonnet`; empty ⇒ inherit).) Apply its feedback, then show the user **both the audit feedback AND the delta it caused** (diff + changed drafts).

### 7. Atomic posting — only on the user's final approval

After the user approves the final package, post in one pass, **in this order**:

1. **Push the head update FIRST.** The `pr/*` head gets the round's fix commit(s) before any reply posts, so the SHAs cited in replies resolve on the PR. (The head-update assumes the `pr/*` head `/open-pr` guarantees; a legacy base-headed PR would mean pushing the base — out of scope, `/open-pr` refuses base-headed PRs going forward.)
2. **One reply per thread**, posted to the thread's **root comment id** (captured in phase 1), citing the fix commit hash **+ a link to its diff** (per "Citing a fix" — anchored to the file/line when the comment is LOC-specific) + `file:line` (or the rationale/refutation). Inline threads: `gh api repos/{owner}/{repo}/pulls/<n>/comments/<root-id>/replies`. Every reply body **starts with the visible `agent-identity.sh tag` line** and **ends with the agent-authored marker**.
3. **Resolve per the reviewer policy** (GraphQL `resolveReviewThread`):
   - `--no-resolve` → resolve nothing.
   - `--resolve`, or "no human reviewer" answered in phase 1 → resolve every addressed thread wholesale.
   - human reviewer present (default) → leave human-raised threads for the human; resolve only a thread whose **ROOT comment is agent-authored** (carries the marker — i.e. the agent originated the point, per the phase-1 authorship capture) **and** a later human comment **affirms** it. "Agent-raised" is a property of the root comment, not the latest one (latest-is-agent and human-responded-after are mutually exclusive). Whether a later human comment counts as affirmation is a body-content judgment — **surface those candidates at triage and let the user confirm**, rather than inferring "affirmed" mechanically.
4. **One numbered round-summary comment** (starts with the `agent-identity.sh tag` line, ends with the marker): every item → disposition, plus what was deferred to which TODO.
5. **Re-request review** (`gh api …/requested_reviewers`).

**Resumable.** Keep a per-round journal (`logs/pr-comments-<n>-round<r>.json`, gitignored) of `{thread_id: posted_reply_id}` as each reply posts. Before posting to a thread, skip it **iff the journal shows it done** this round. The journal is the *sole* resume authority — do NOT use the agent-authored marker to detect "already serviced": that marker is round-agnostic (byte-identical every round), so it can't tell a reply posted in the current failed pass from one posted three rounds ago, and would wrongly skip a thread that legitimately needs a fresh reply. A partial-failure retry keyed on the round journal is idempotent, never double-posting.

Posting is all-or-nothing per the approved package — no partial early posts, no edits after approval without re-approval.

## What This Skill Will NOT Do

- Post, resolve, or push anything outward before the user approves the final package (`--dry-run` never posts at all).
- Treat any comment — including the user's own — as correct without investigation, or as an implementation directive without asking.
- **Refute a code/contract claim by paraphrase** — quote the actual `file:line` source so the refutation is self-checkable.
- Resolve a human reviewer's own thread on their behalf when a human reviewer is in the loop (they resolve when satisfied; the agent only resolves agent-raised threads a human has affirmed, or everything when there's no human reviewer).
- Service items one-by-one when they cluster, or end a round with undispositioned items.
- Mutate TODO↔PR tags directly — tag updates go through `/open-pr`'s tagging step.
- **Update an open PR by building the change on a local/base/feature branch and leaving the PR head untouched (orphaning it).** Fixes land on the PR's own head branch (checkout → commit → push), same as `/open-pr` Update mode. This is the DX-jn-8-026 lesson (PR #86 was rebuilt locally and had to be closed). For a **substantive change beyond dispositioning review comments**, hand off to `/open-pr --update <n>`.

## Companion Skills

- **`open-pr`** — opened the PR; owns TODO tagging + the `pr:` back-pointer this skill's phase 5 updates route through.
- **`todo`** — `reopen` / mint / body-update mechanics for ledger linkage.
- **`.claude/agents/reviewer.md`** — the reviewer definition behind phase 5's diff review and phase 6's package audit (mode 2).

---

**Skill Version**: 1.6.0
**Category**: Workflow, GitHub
_Version history: see [CHANGELOG.md](./CHANGELOG.md)._
