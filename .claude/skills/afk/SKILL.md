---
name: afk
description: Drive a task to completion autonomously while the user is away (AFK). Implements as far as possible, runs the review loop and the test loop with reviewer/tester subagents until green, closes the TODO, and lands the work into the local base branch — stopping only for genuinely blocking questions (surfaced after review + test). Refrains from asking questions unless necessary. Use when the user says "AFK", "run this autonomously", "drive this to done", "ship this unattended", "take it from here".
---

# afk — autonomous task driver

You are about to run **unattended**. The user is away and wants this task carried to "done" with no hand-holding. Your job is to be maximally autonomous **and** maximally safe: keep moving without asking questions, but stop cleanly (and loudly) when you genuinely can't proceed.

## Invocation

```
/afk [test-first] [--todo <ID>] [--max-rounds N] [--publish] [--pr-on-close]
```

- **`test-first`** — flavor B (test/fix loop *before* review). Default is flavor A (implement first).
- **`--todo <ID>`** — the TODO this task closes (else infer from the task / branch; skip closing if none applies).
- **`--max-rounds N`** (default `5`) — cap per loop (review, test). On reaching it, STOP and surface — never loop forever unattended.
- **`--publish`** — on a clean run, after landing into local `<base>`, also `/base-push` to publish `origin/<base>`. **Default is land-local-only** — afk lands the work into the local base and stops there, so you review on return and publish yourself. Publishing is the one origin write afk can do, and only with this explicit opt-in.
- **`--pr-on-close`** — on a clean run, after closing the TODO, prepare a GitHub PR via `/open-pr <ID>` up to (but never past) its user-gated create step: branch, scope, gates, and the title/body package are ready; `gh pr create` itself waits for the user's return (PR creation is outward-facing — the autonomy contract's "never touch origin" exception does NOT extend to it). Without this flag, `/afk` skips the PR offer entirely.

The **task** is the work the user set up before invoking this (the current branch's in-progress changes and/or the referenced TODO). You own all the code and all the fixes; the reviewer and tester **subagents** ([`reviewer`](../../agents/reviewer.md), [`tester`](../../agents/tester.md) — spawned via the Agent tool) are **services** you consult. They need no liveness management: a spawn either returns a result or errors, and a dead one is respawned under the same name with nothing lost.

> **Solo vs fleet:** the review and test loops are identical in both modes — the subagents
> are local, not fleet peers. Only **Finish** differs: fleet mode lands via
> `/base-merge up` / `/base-push`; **solo mode** (`WORKFLOW_FLEET_MODE=0`) lands via
> **plain git** on the branch/trunk the user pre-specified (never `/base-push` /
> `/base-merge` — disabled solo), and never touches origin unless the user pre-authorized
> a `git push`. Everything else (autonomy contract, journal, blocked-path stop,
> max-rounds) is unchanged.

> **Plan authoring + review gate first:** author the plan via the
> [`planner`](../../agents/planner.md) subagent (`model` = `WORKFLOW_PLAN_MODEL`, default
> `fable`) — under `/afk` it plans **autonomously** (no human attaches to steer; it records
> open questions in the plan). Then, if the TODO's plan has no recorded `plan_review:`
> outcome (see the `todo` skill's start step 4) and the plan is complex, run the gate BEFORE
> implementing — under `/afk` the gate is not shown (no human): Q1 = **No Monocle**,
> Q2 = **Two reviewers** (`rev-a` + `rev-b`, dispatched together, both **PLAN GREEN**).

## Autonomy contract

- **`/afk` is the SOLE exception to the per-commit user-review gate.** The normal
  human-in-the-loop flow (feature.md / `/todo`) stops for the user's review of the
  uncommitted change *before every commit*; `/afk` runs unattended, so it commits on its own
  (agent review + the test sweep substitute) and the user reviews everything **on return**.
  This is the whole point of `/afk` — do not stop for per-commit user review here.
- **Do not ask questions unless genuinely blocked.** A decision with a sensible default is NOT a blocker: pick the default, **log it in the journal**, and keep going. The user reviews your choices on return.
- **Blocking question** = something whose answer changes the implementation and has no safe default. When you hit one: implement everything you safely can around it, run it through review + test anyway, then **stop before the final merge** and present the accumulated questions (see Finish → blocked path).
- **Stay in scope.** Implement the task; do not opportunistically refactor unrelated code while unsupervised.
- **Never** `--no-verify`, `--amend` published commits, force-push, run destructive git, or broadcast/fan-out to fleet agents. Reviewer/tester subagent spawns are local and always sanctioned.
- **Never touch origin** except the `/base-push` in Finish that runs ONLY when `--publish` was passed (default: land into local base, no origin touch). Coordination is the local base branch (`WORKFLOW_BASE_BRANCH`).

## Step 0 — Plan echo + journal

Before going dark, write a one-screen plan and open the journal so the unattended run is auditable.

```bash
BRANCH=$(git rev-parse --abbrev-ref HEAD)
JOURNAL="logs/afk-$BRANCH.md"   # logs/ is gitignored
mkdir -p logs
```

Print and append to `$JOURNAL`: the task, flavor (A/B), `--max-rounds`, the TODO ID, the planner/reviewer/tester models in effect (`WORKFLOW_PLAN_MODEL` [default `fable`] / `WORKFLOW_REVIEW_MODEL_A`+`_B` [rev-a `fable` / rev-b `sonnet`] / `WORKFLOW_TEST_MODEL`, or "inherit"), the merge policy ("land into local base; publish to origin only if --publish"), and the exact stop conditions. Keep appending a timestamped line at every state transition, every review finding + how you resolved it, every non-blocking default you picked, and every test result. This journal is also your **resume state** if the run is interrupted (context compaction, restart) — on resume, read it to find where you left off.

## State machine

**Flavor A (default — implement first):**
1. Implement the task as far as you safely can (respecting blocking questions).
2. **Documentation sync** (§ Doc-sync) — before review.
3. **Review loop** (§ Review).
4. Commit the fixes (conventional commit; reference the TODO ID).
5. **Test loop** (§ Test).
6. **Finish** (§ Finish).

**Flavor B (`test-first`):**
1. **Test loop** first — get the current state green.
2. **Documentation sync** (§ Doc-sync) — once the implementation is settled, before review.
3. **Review loop**.
4. Commit.
5. **Test loop** again (final tests).
6. **Finish**.

## Doc-sync

Before review, run the documentation-sync step ([`docs/doc-sync.md`](../../../docs/doc-sync.md), if the project has one) so the docs land in the same diff the reviewer sees:

- **Encode the product/business decisions** this work made into the **product docs** — the overview doc, or a topic doc you see fit linked from its index — the rule/flow/limit/default you established or changed, and a sentence of *why*.
- **Reconcile every doc the changed code touched** — best-practices, testing, `architecture.md`, security docs, any API docs (regenerate them), the relevant `CLAUDE.md` — per the map in `doc-sync.md`.
- Keep it proportionate (a typo needs none; a behavior change almost always touches the product docs). Log what you synced in the journal. The reviewer's doc-drift dimension will catch anything missed.

## Review loop

**Reviewers under `/afk` — No Monocle + Two reviewers, no prompt.** `/afk` never shows the
two-axis review gate (no human to answer): Q1 = **No Monocle**, Q2 = **Two reviewers** —
two independent spawns of the [`reviewer`](../../agents/reviewer.md) definition
(`rev-a` + `rev-b`), dispatched together each round; the round is GREEN only when **both**
are. (Two independent readers is the unattended substitute for the human's eye.)

Repeat up to `--max-rounds`:

1. Commit any pending work first (so the reviewers see a clean SHA). **Spawn both
   reviewers at once** (Agent tool, `subagent_type: reviewer`, names `rev-a`/`rev-b`,
   `model` model-diverse: rev-a = `WORKFLOW_REVIEW_MODEL_A` (`fable`), rev-b =
   `WORKFLOW_REVIEW_MODEL_B` (`sonnet`), each empty ⇒ omit) with the definition's
   **mode-1 contract**: the TODO id, `type: diff`, the commit SHA/range, the pin SHA,
   and any business decisions not yet in the files.
2. **Collect both verdicts.** A spawn returns its verdict as its result (or errors —
   respawn once under the same name; a second consecutive error on the same round is a
   Stop condition). No liveness-watching, no failover pool: the Agent tool always
   resolves.
3. **Parse both — GREEN LIGHT required from each.**
   - **Both green** → exit the loop.
   - **Findings from either** → fix every blocker (and reasonable nits) from **both**; if
     a finding is itself a blocking question with no safe default, record it and address
     what you can. Append each finding + resolution to the journal. Commit the fixes,
     then loop — **resume the SAME named reviewers** (SendMessage to `rev-a`/`rev-b` with
     the fix SHA; the fix-round audit is by SHA, first-class).
4. **Cap / non-convergence.** If you reach `--max-rounds`, or the same finding keeps
   recurring (a reviewer isn't converging), **Stop** and surface the state — do not keep
   looping.

## Test loop

1. **Spawn the [`tester`](../../agents/tester.md)** (Agent tool, `subagent_type: tester`,
   name `tester`, `model` = `WORKFLOW_TEST_MODEL` when set, else omit) **in place on the
   branch**: "Full sweep. Changed range: `<base>..<BRANCH>`." The tester makes zero
   git/source mutations and serializes any resource-bound phase (integration / E2E)
   through the project's machine-wide test lock itself, if one is wired — long waits on
   the lock are normal when another worktree is mid-sweep; its report says what ran.
2. **Parse:** PASS → exit. Failures → **you** fix them (the tester reports; you own the
   code), commit, then re-run — resume the same `tester` (SendMessage: "re-run the failed
   gates") or respawn for a full sweep. Append results to the journal.
3. Cap at `--max-rounds`; on non-convergence Stop and surface.

(Quick local gates — type-check, the relevant unit tests, lint — are fine to run yourself in-place before spawning, to avoid burning a full-sweep round on something you can catch locally.)

## Finish

Once review is green **and** tests pass:

- **Clean run (no blocking questions accumulated):**
  1. Close the TODO if applicable — use the `todo` skill to move `docs/todos/<ID>.md` → `docs/todos/completed/` with the **work commits** referenced in `commits:` (the merge lands in step 2, so there's no merge SHA yet — same as `/todo done`), then regenerate the TODO index. This close lands on the feature branch, so it rides in the diff step 2 merges (close-before-publish). Skip if no TODO applies.
  2. **Land (and optionally publish) through the base skills — never hand-roll the merge or push.**
     - **Default (land local only):** run **`/base-merge up`** — it lands the branch into local `<base>` via `merge_into_branch_local`, no origin touch. The work is then on the local base for you to review + publish on return.
     - **`--publish`:** run **`/base-push`** instead — it does the same local land AND publishes `origin/<base>` with the **non-fast-forward guard** (the protection a raw `git push origin <base>` skips — a guardless push could mutate a frozen `origin/<base>`, e.g. the SHA backing an open PR). This is the one sanctioned origin touch, and only with the explicit `--publish` opt-in.
     - **Honor the merge return codes** (`merge-helpers.sh` contract): `1` worktree-add failure · `2` conflict (worktree preserved) · `3` post-merge regen/commit failure (worktree preserved). On ANY non-zero, or on a non-fast-forward push rejection from `/base-push`, **STOP** (this is a Stop condition: "merge conflict landing into the base") and surface the state in the report — never force, never retry the push blindly.
  3. If `--pr-on-close`: run `/open-pr <ID>` up to its create gate (branch + scope + gates + package ready); the user approves `gh pr create` on return. Note the prepared package in the report.
  4. Notify + final report.

- **Blocked path (one or more blocking questions accumulated):**
  1. Do **not** merge or publish. Leave the work committed on the branch and landed-ready.
  2. Notify + final report, with the **blocking questions front and center** — clearly numbered, each with the context and the options you see, so the user can answer fast on return. Note that review + test already passed on what's implemented.

## Notify + final report

The user is AFK, so actively get their attention, then leave a complete written report.

```bash
# macOS native desktop notification (always available); also ring the bell.
osascript -e 'display notification "<one-line status>" with title "AFK run: <BRANCH>"' 2>/dev/null || true
printf '\a'   # terminal bell
```
(If the `claude-notifications` plugin is configured, use it instead/as well.)

The **final report** (terminal + appended to `$JOURNAL`):
- Outcome: **MERGED (+published?)**, or **STOPPED — needs you** (blocking questions / cap hit / subagent errors).
- What was implemented (commits: hashes + subjects).
- Review: rounds taken, every finding + how it was resolved, final GREEN (both reviewers).
- Tests: rounds, final PASS (or the failure that stopped it).
- Non-blocking defaults you chose (so the user can veto on return).
- **Blocking questions**, numbered, if any.
- TODO status, merge SHA on the local base, publish status.

## Stop conditions (always notify + report)

- A **blocking question** with no safe default — after review + test on what's implemented.
- **Cap reached** (`--max-rounds`) or a loop not converging.
- A reviewer or tester spawn **errors twice consecutively** on the same round (respawn once, then stop — something environmental is wrong).
- A **merge conflict** landing into the base, or any gate you cannot fix within scope.
- Anything that would require an action the contract forbids (origin write beyond the sanctioned publish, destructive git, out-of-scope change).

## What this skill will NOT do

- Ask questions for anything with a sensible default (pick it, log it, continue).
- Loop forever — every loop is capped.
- Touch origin except the `/base-push` that runs only when `--publish` was passed (default: land into local base, no origin touch).
- Broadcast/fan-out to fleet agents, force-push, `--no-verify`, `--amend` published commits, or wander outside the task's scope.
- Merge or publish when blocking questions remain — it stops and asks instead.

---

**Skill Version**: 3.0.0
**Category**: Workflow, Autonomous

_Version history: see [CHANGELOG.md](./CHANGELOG.md)._
