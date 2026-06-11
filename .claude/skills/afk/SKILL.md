---
name: afk
description: Drive a task to completion autonomously while the user is away (AFK). Implements as far as possible, runs the PR-review loop and the test loop with peer agents until green, closes the TODO, and lands the work into the local base branch — stopping only for genuinely blocking questions (surfaced after PR + test). Refrains from asking questions unless necessary. Use when the user says "AFK", "run this autonomously", "drive this to done", "ship this unattended", "take it from here".
---

# afk — autonomous task driver

You are about to run **unattended**. The user is away and wants this task carried to "done" with no hand-holding. Your job is to be maximally autonomous **and** maximally safe: keep moving without asking questions, but stop cleanly (and loudly) when you genuinely can't proceed.

## Invocation

```
/afk [test-first] --pr <agent> [--test <agent>] [--todo <ID>] [--max-rounds N] [--no-publish]
```

- **`--pr <agent[,agent2,…]>`** (required) — the PR reviewer(s), as a **failover priority list** (e.g. `pr-2,pr`). `/afk` uses the first; if it's dead or never picks up / never replies within the timeout, it advances to the next — and may additionally discover other live `*pr*`-named peers as further fallbacks. List live agents: `ls ~/.claude/running-agents/ | sed 's/\.[0-9]*$//' | sort -u`.
- **`--test <agent>`** (default: `WORKFLOW_TESTING_AGENT` from config, else ask) — the peer agent that runs the test sweep.
- **`test-first`** — flavor B (test/fix loop *before* review). Default is flavor A (implement first).
- **`--todo <ID>`** — the TODO this task closes (else infer from the task / branch; skip closing if none applies).
- **`--max-rounds N`** (default `5`) — cap per loop (review, test). On reaching it, STOP and surface — never loop forever unattended.
- **`--no-publish`** — never `/base-push`, even on a clean run (default: publish only if the run finished with zero blocking questions — see Finish).

The **task** is the work the user set up before invoking this (the current branch's in-progress changes and/or the referenced TODO). You own all the code and all the fixes; the `--pr` and `--test` agents are **services** you consult.

## Autonomy contract

- **Do not ask questions unless genuinely blocked.** A decision with a sensible default is NOT a blocker: pick the default, **log it in the journal**, and keep going. The user reviews your choices on return.
- **Blocking question** = something whose answer changes the implementation and has no safe default. When you hit one: implement everything you safely can around it, run it through PR + test anyway, then **stop before the final merge** and present the accumulated questions (see Finish → blocked path).
- **Stay in scope.** Implement the task; do not opportunistically refactor unrelated code while unsupervised.
- **Never** `--no-verify`, `--amend` published commits, force-push, run destructive git, or broadcast/fan-out to other agents. The only peers you message are `--pr` and `--test`.
- **Never touch origin** except the optional final `/base-push` (Finish). Coordination is the local base branch.

## Step 0 — Plan echo + journal

Before going dark, write a one-screen plan and open the journal so the unattended run is auditable.

```bash
source "$(git rev-parse --show-toplevel)/.claude/scripts/_config.sh"
BRANCH=$(git rev-parse --abbrev-ref HEAD)
JOURNAL="logs/afk-$BRANCH.md"   # logs/ should be gitignored
mkdir -p logs
```

Print and append to `$JOURNAL`: the task, flavor (A/B), `--pr`/`--test` agents, `--max-rounds`, the TODO ID, the merge policy ("local; publish if clean"), and the exact stop conditions. Keep appending a timestamped line at every state transition, every PR finding + how you resolved it, every non-blocking default you picked, and every test result. This journal is also your **resume state** if the run is interrupted (context compaction, restart) — on resume, read it to find where you left off.

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

Before review, run the documentation-sync step (the `todo` skill's "Doc-sync / doc-drift check", or `docs/doc-sync.md` if the project has one) so the docs land in the same diff the reviewer sees:

- **Encode the product/business decisions** this work made into the **product docs** — `docs/product.md` for overview, or a topic doc linked from its index — the rule/flow/limit/default you established or changed, and a sentence of *why*.
- **Reconcile every doc the changed code touched** — `docs/architecture.md` (a component/dependency/data-flow/invariant change MUST be reflected here), the best-practices doc(s), `docs/testing.md`, `docs/security.md`, the API spec (regenerate if a route/shape changed), and the relevant `CLAUDE.md`.
- Keep it proportionate (a typo needs none; a behavior change almost always touches `product.md` and often `architecture.md`). Log what you synced in the journal. The reviewer's doc-drift dimension will catch anything missed.

## Review loop

Repeat up to `--max-rounds`:

1. Commit any pending work first (so the reviewer sees a clean branch). Send the review request — **always `--stdin` heredoc** so nothing in the body gets shell-expanded:
   ```bash
   .claude/scripts/agent-send.sh <pr-agent> --stdin <<'BODY'
   AFK review request — branch <BRANCH> @<sha>. Review locally: git diff <base>...<BRANCH>
   Task: <one-line task summary>. Focus: <anything specific>.
   Reply --reply with "GREEN LIGHT" if approved, or your findings (blockers vs nits). I'm driving an autonomous run and will fix + resend until green.
   BODY
   ```
   Capture the staged request path from `agent-send`'s output (`msg=<reviewer>/<uuid>.<self>.req.txt`) — you'll watch it for receipt below. Resolve `<self>` from the registry (the file in `~/.claude/running-agents/` whose contents == `$TMUX_PANE`; its name is `<self>`).
2. **Wait for the reply — and in parallel watch receipt + liveness.** The reviewer's `--reply` lands durably at `~/.claude/agent-inbox/<self>/*.<reviewer>.rep.txt` (per-recipient mailbox — you don't depend on a live nudge). Wait until that file appears, using the **Monitor** tool with an until-condition (foreground `sleep` is blocked). **A prompt reviewer makes this instant — the file shows up in seconds and you skip straight to step 3.** While waiting, interpret the two side-signals so you never sit blind on a stalled or dead reviewer:

   | Your request file | Reviewer state | Meaning → action |
   |---|---|---|
   | **consumed** (deleted) | any | ✅ picked up & reviewing — keep waiting (silence is fine) |
   | still present | busy (`~/.claude/agent-busy/<reviewer>` fresh) | normal — they'll drain it at their next Stop; keep waiting |
   | still present | **idle** for a while (no busy marker, several min) | ⚠️ drain should have delivered — re-stage/re-nudge once; if still no pickup → **fail over** |
   | (either) | **PID/pane gone** (`kill -0` fails or pane missing) | 💀 **fail over** immediately |

   Suggested overall cap per reviewer: ~30 min after pickup (longer if the diff is large). On reply: you consume the file yourself (read + delete, like `agent-msg`). If the verdict instead arrives via a `/agent-msg … reply` turn (the run briefly yielded), handle it identically — the journal says you're mid-AFK, so route it into this loop rather than just integrating it.
3. **Reviewer failover.** When step 2 says "fail over": advance to the next agent in the `--pr` list (or, if exhausted, a freshly-discovered live `*pr*`-named peer not already tried). Re-stage the same request to it, note the failover in the journal, and resume the wait. If **no** reviewer in the pool is reachable → **Stop** and notify (don't merge unreviewed).
4. **Parse the verdict.** Look for an explicit **GREEN LIGHT** (approval). Otherwise treat the reply as findings.
   - **Green** → exit the loop.
   - **Findings** → fix every blocker (and reasonable nits); if a finding is itself a blocking question with no safe default, record it and address what you can. Append each finding + resolution to the journal. Commit the fixes, then loop (resend so the reviewer re-reviews the fixed branch — prefer the same reviewer for continuity).
5. **Cap / non-convergence.** If you reach `--max-rounds`, or the same finding keeps recurring (the reviewer isn't converging), **Stop** and surface the state — do not keep looping.

## Test loop

Same shape, with the `--test` agent:

1. Send a test request (`--stdin`): "Run the gate sweep against branch `<BRANCH>` @`<sha>` and reply --reply with PASS or the failures."
2. Wait for `*.<test-agent>.rep.txt` the same way — same receipt + liveness watching as the review loop (these runs take a while — the E2E sweep especially; size the timeout generously, e.g. 45–60 min, re-checking liveness). If the test agent dies, fail over to another live `*test*`-named peer if one exists, else Stop.
3. **Parse:** PASS → exit. Failures → **you** fix them (the test agent reports; you own the code), commit, resend. Append results to the journal.
4. Cap at `--max-rounds`; on non-convergence Stop and surface.

(Quick local gates — type-check, the relevant unit tests, lint — are fine to run yourself in-place before sending, to avoid burning a remote round on something you can catch locally.)

## Finish

Once review is green **and** tests pass:

- **Clean run (no blocking questions accumulated):**
  1. Close the TODO if applicable — use the `todo` skill to move `docs/todos/<ID>.md` → `docs/todos/completed/` with the merge commit referenced (then run the generator). Skip if no TODO applies.
  2. Land into the **local** base: `/base-merge up` (or `merge_into_branch_local "$WORKFLOW_BASE_BRANCH" "$BRANCH" "..."` directly). **No origin push here.**
  3. **Publish** only if `--no-publish` was NOT passed: `/base-push` (the pre-push hook runs the gates). This is the one origin touch, allowed because the user opted into "publish if clean."
  4. Notify + final report.

- **Blocked path (one or more blocking questions accumulated):**
  1. Do **not** merge or publish. Leave the work committed on the branch and landed-ready.
  2. Notify + final report, with the **blocking questions front and center** — clearly numbered, each with the context and the options you see, so the user can answer fast on return. Note that PR + test already passed on what's implemented.

## Notify + final report

The user is AFK, so actively get their attention, then leave a complete written report.

```bash
# macOS native desktop notification; also ring the bell. (Adapt for Linux: notify-send.)
osascript -e 'display notification "<one-line status>" with title "AFK run: <BRANCH>"' 2>/dev/null || true
printf '\a'   # terminal bell
```

The **final report** (terminal + appended to `$JOURNAL`):
- Outcome: **MERGED (+published?)**, or **STOPPED — needs you** (blocking questions / cap hit / agent unresponsive).
- What was implemented (commits: hashes + subjects).
- Review: rounds taken, every finding + how it was resolved, final GREEN.
- Tests: rounds, final PASS (or the failure that stopped it).
- Non-blocking defaults you chose (so the user can veto on return).
- **Blocking questions**, numbered, if any.
- TODO status, merge SHA on local base, publish status.

## Stop conditions (always notify + report)

- A **blocking question** with no safe default — after PR + test on what's implemented.
- **Cap reached** (`--max-rounds`) or a loop not converging.
- The **entire reviewer pool exhausted** — every `--pr` agent (and any discovered `*pr*` fallback) is dead or unresponsive past its timeout.
- A **merge conflict** landing into the base, or any gate you cannot fix within scope.
- Anything that would require an action the contract forbids (origin write beyond the sanctioned publish, destructive git, out-of-scope change).

## What this skill will NOT do

- Ask questions for anything with a sensible default (pick it, log it, continue).
- Loop forever — every loop is capped and every wait has a timeout.
- Touch origin except the optional final `/base-push` on a clean run.
- Broadcast/fan-out, force-push, `--no-verify`, `--amend` published commits, or wander outside the task's scope.
- Merge or publish when blocking questions remain — it stops and asks instead.
