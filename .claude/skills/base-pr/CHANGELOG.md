# base-pr — changelog

## Changelog

- **1.2.0** — (dedicated review branch) base-pr now operates on a reserved review
  branch (`WORKFLOW_REVIEW_BRANCH`, default `<base>-review`, per-base): step 1
  switches to (or creates) it on a clean tree and **refuses on a feature branch
  with uncommitted changes**, so the step-10 promotion can never push a feature
  branch's *unreviewed* commits into `<base>` (the prior in-place model only
  refused `base`/`master`/`main` by name). Makes the `<base>-review` reservation
  in `/base-push` + `/base-merge` real again. The read-only `--pr <n>` GitHub mode
  is unaffected.
- **1.1.0** — (merge-helper hardening) Step 0 now **sources
  `.claude/scripts/merge-helpers.sh`** (the helper was extracted there from
  `base-push`; this skill never sourced `base-push`, so the step-10 promotion
  call had no definition in scope). Step 10 now also routes return code **3**
  (post-merge regen/commit failure, transient worktree preserved) alongside
  0/1/2.
