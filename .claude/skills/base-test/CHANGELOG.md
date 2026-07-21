# base-test — changelog

## Changelog

- **2.0.0** — **Subagent convergence (DX-jn-cc-017).** Rewritten as a thin stub that
  **spawns the [`tester`](../../agents/tester.md) definition in place** on the current
  worktree (model `WORKFLOW_TEST_MODEL`) — it owns the gate catalog + any test lock and
  makes zero git/source mutations. The old in-worktree checkout / `--with-base` / `--as-is`
  / `--pr` modes are retired: the CALLER arranges the tree (`/base-merge down` replaces
  `--with-base`; a scratch worktree for another branch/PR). Remains a PROJECT-OWNED stub
  (never synced by `/update-workflow`).
- **1.2.0** — **Branch-flexible target, symmetric with `base-pr`.** The skill now
  takes an optional `<target>` (omitted → current branch; a local branch / SHA /
  tag → checked out in this worktree; `--pr <n>` → fetched PR head, detached) so
  it can test ANY branch, not just the current one. The base-merge is demoted to
  an optional modifier `--with-base` (**default ON** — "usually if something hits
  base it's already tested"); `--as-is` (alias of the old "skip the sync" / "test
  as-is" phrases) tests the target exactly. **Special case: the literal base
  branch is NEVER checked out** (a worktree on `<base>` breaks `git worktree add
  <base>` for every other agent) — "test base" falls back to the default model
  (merge local `<base>` into the current feature branch and test). New step 2
  checks out the target; the old step-2 merge becomes step 3 (gates → 4,
  diagnose → 5, report → 6). **Testing mutates the worktree** (it's left on the
  target — unlike review, which is read-only). The `merge-helpers.sh` source, the
  `git merge --abort` recovery, and the full gate list are unchanged.
- **1.1.0** — (merge-helper hardening) Step 0 now **sources
  `.claude/scripts/merge-helpers.sh`** — the fix for step 2 calling
  `regen_merged_artifacts`, which previously lived inline in `base-push` and was
  never sourced here (`command not found` mid-merge). Step 2's clean-merge regen
  failure and the conflict path now point at `git merge --abort` (resets to
  `PRE_MERGE_SHA`).
