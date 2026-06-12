---
name: pr-comments
description: Methodically service a GitHub PR's review round — complete comment inventory across all three surfaces, critical investigation of every claim before any disposition (refuting wrong feedback with evidence is a first-class outcome), clustered triage with the user while reply drafts accumulate UNPOSTED, implementation through the internal review flow with TODO ledger linkage, a peer package-audit near the end, and atomic posting only on the user's final approval. Use when the user says "go through the PR comments", "service the review feedback", "address the comments on PR <n>".
---

# pr-comments — service a PR review round, methodically

Work through every comment on a PR with full inventory, critical verification, user-in-the-loop triage, and **nothing posted to GitHub until the user's final approval**. One invocation = one review round, ending in one atomic posting pass.

## When to Use

- "Go through the comments on PR 12" / "we got review feedback, address it".
- A reviewer finished a round on a PR opened via `/open-pr` (or any PR).

**Do NOT use** for opening PRs (`/open-pr`) or for internal fleet review (`/base-pr`, `agent-send`).

## Invocation

```
/pr-comments <n> [--dry-run] [--no-resolve] [--reply-only]
```

- `--dry-run` — phases 1–3 only (inventory + investigation + triage proposal); nothing implemented, nothing posted.
- `--no-resolve` — post replies but never resolve threads (leave that to the reviewer).
- `--reply-only` — no code changes expected (e.g. answering questions); skips phases 4–5.

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

Build the **checklist**: every thread/comment gets an id, author, anchor, and an empty disposition. Already-resolved threads are listed (for context) but not serviced. **Every item ends the round with an explicit disposition** — `fixed` / `explained` / `deferred → TODO` / `disagree + rationale`. No silent drops.

### 2. Author awareness — context, not authority

Resolve the user's own GitHub login (`gh api user -q .login`) and attribute their comments as **the user's** in the inventory and triage. This is **identity context, not an authority bypass**: their comments are investigated exactly like any other (phase 3), and if one reads like a request for a specific implementation, **ASK the user whether that's what they want** before building it — don't infer a directive from a comment.

### 3. Investigate before believing

**Every comment is verified against the code/docs/tests BEFORE a disposition is proposed.** Reviewers are sometimes wrong; an agreeable agent that "fixes" a non-issue makes the code worse. Per item, record one of:

- **confirmed** — the claim checks out (cite the evidence).
- **partially right** — what holds, what doesn't.
- **refuted** — with `file:line` evidence. The draft reply is a respectful, evidence-backed explanation — refuting wrong feedback is a first-class outcome, not a failure to comply.
- **needs-discussion** — genuinely ambiguous or a judgment call → triage with the user.

### 4. Clustered triage with the user — drafts accumulate, NOTHING posts

Group related comments (same file, same theme, same root cause) and discuss each **cluster in one shot** — never march one-by-one through items that share an answer. For each cluster present: the comments, the investigation outcomes, the proposed dispositions, and a **draft reply per thread**. The user adjusts course as you go; drafts evolve alongside.

**Hard rule: nothing posts during this phase.** Drafts live locally until phase 7.

### 5. Implement accepted fixes — internal flow + TODO linkage

Fixes go through the normal internal flow: implement on the working branch, gates, peer diff review for substantive changes, then onto the `pr/*` branch (cherry-pick or re-split, matching how the PR was scoped — and push to the `pr/*` head only as part of phase 7's approved package).

**TODO ledger linkage** (the PR's tag block tells you the ID; tag updates go through `/open-pr` step 6 so the implementation stays single):

- **Substantive comments on a completed TODO** → either `/todo reopen <ID>` (optionally for another agent to pick up) or fix directly and UPDATE the completed TODO's body with the findings/changes, appending the fix commits to `commits:`.
- **Findings outside the original scope** → recommend a NEW TODO rather than silently widening this one.
- Deferred items get a real TODO minted (`deferred → TODO` dispositions must reference the minted ID).

### 6. Package audit — peer review of the whole round (near-last)

Bundle = original comments + the implementation diff + every draft reply. Send it to a live review-role agent (classifier: `.claude/scripts/agent-fanout.sh status`, ROLE `review`) to audit **coherence**: do the fixes actually address the comments; do the replies describe the fixes accurately; are the refutations correct; is anything left unanswered? Apply its feedback, then show the user **both the audit feedback AND the delta it caused** (diff + changed drafts).

### 7. Atomic posting — only on the user's final approval

After the user approves the final package, post in one pass:

- One reply per thread, citing the fix commit + `file:line` (or the rationale/refutation). Inline threads: `gh api repos/{owner}/{repo}/pulls/<n>/comments/<id>/replies`.
- Resolve addressed threads via GraphQL `resolveReviewThread` (skip with `--no-resolve`).
- One **numbered round-summary comment** on the PR: every item → disposition, plus what was deferred to which TODO.
- Push the `pr/*` head update and re-request review (`gh pr edit --add-reviewer` / `gh api …/requested_reviewers`).

Posting is all-or-nothing per the approved package — no partial early posts, no edits after approval without re-approval.

## What This Skill Will NOT Do

- Post, resolve, or push anything outward before the user approves the final package (`--dry-run` never posts at all).
- Treat any comment — including the user's own — as correct without investigation, or as an implementation directive without asking.
- Service items one-by-one when they cluster, or end a round with undispositioned items.
- Mutate TODO↔PR tags directly — tag updates go through `/open-pr`'s tagging step.

## Companion Skills

- **`open-pr`** — opened the PR; owns TODO tagging + the `pr:` back-pointer this skill's phase 5 updates route through.
- **`todo`** — `reopen` / mint / body-update mechanics for ledger linkage.
- **`base-pr`** — the internal diff reviewer used in phase 5; a review-role agent runs phase 6's package audit.

---

**Skill Version**: 1.0.0
**Category**: Workflow, GitHub

## Changelog

- **1.0.0** — Initial: 3-surface paginated inventory + GraphQL resolved-state,
  author-context (not authority), investigate-before-believing with refutation as a
  first-class outcome, clustered triage with unposted drafts, internal-flow
  implementation + TODO ledger linkage via /open-pr, peer package audit, atomic
  user-gated posting. (DX-8011.)
