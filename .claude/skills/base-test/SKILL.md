---
name: base-test
description: Run the project's full quality-gate sweep by spawning the tester subagent IN PLACE on the current worktree. The tester owns the gate catalog (whatever your CLAUDE.md / CI defines + any E2E) and any machine-wide test lock; this stub is the invocation recipe — including how to test another branch/PR/the base (the CALLER arranges the tree; the tester never mutates git). Use for "run base-test", "test my branch", "run the gates".
---

# base-test — spawn the tester on this worktree

> **PROJECT-OWNED stub.** `/update-workflow` never syncs this file — each project fills in
> its own gate catalog. The sweep itself lives in the [`tester`](../../agents/tester.md)
> definition (which reads your `CLAUDE.md` for the authoritative gate list); this stub is
> just the invocation recipe. Tailor the Scope / Concurrency sections to your stack.

## Invocation

**Spawn the tester** — Agent tool, `subagent_type: tester`, `model` =
`WORKFLOW_TEST_MODEL` when set (else omit ⇒ inherit). Prompt: what to run (default:
the full sweep) and the **changed range** for the post-GREEN missing-tests advisory
(e.g. `<base>..HEAD`). It tests **whatever is checked out, in place** — uncommitted
work included — and makes zero git/source mutations. Fix failures yourself and re-run
(resume the same `tester` via SendMessage for the failed gates, or respawn for a full
sweep).

Solo or fleet, same spawn — there is no peer involved.

## The caller arranges the tree (retired modes)

The old base-test checked targets out itself and merged the base in. **Retired** — the
tester never mutates git, so YOU set the tree up first:

- **Test the current branch as-is** (old `--as-is`): just spawn.
- **"Will this be green once it lands on base?"** (old `--with-base` default):
  `/base-merge down` first (merges local `<base>` into your branch — the merge commit
  stays local), then spawn. Note in the request that the range includes the merge.
- **Test another local branch / SHA / tag** (old `<target>`): check it out in a
  worktree that's free for it — your own (commit/stash first) or a scratch worktree
  (`git worktree add`) — and spawn the tester there.
- **Test a GitHub PR** (old `--pr <n>`): `gh pr checkout <n>` in a **scratch** worktree,
  spawn the tester there, remove the worktree after.
- **"Test the base"**: never check out the literal `<base>` (a worktree sitting on it
  blocks `git worktree add <base>` for every other agent — the standing reservation).
  Use the merge-down recipe above instead.

## Concurrency

If your test sweep has a phase bound to fixed host resources (a test DB, Redis, fixed
ports — anything a second concurrent run would collide on), it must be serialized
machine-wide, one run at a time. The tester serializes it itself when the project wires a
lock (e.g. a `.claude/scripts/e2e-lock.sh` liveness-heartbeat lock). A long wait usually
means another worktree is mid-sweep. Scale throughput by adding feature agents, not by
breaking the lock. _(Fill in your project's lock + resource names.)_

## Scope

_(Fill in what the sweep covers and what is out of scope — e.g. which workspaces, and
which subsystems run under a separate workflow. Manual/browser QA is typically a separate,
explicit request.)_

## Companions

- **[`tester`](../../agents/tester.md)** — owns the catalog, any lock, the report shape.
- **[`base-merge`](../base-merge/SKILL.md)** — the merge-down that replaces `--with-base`.
- **[`base-pr`](../base-pr/SKILL.md)** — the review counterpart.

---

**Skill Version**: 2.0.0
**Category**: Quality / Test Gate

_Version history: see [CHANGELOG.md](./CHANGELOG.md)._
