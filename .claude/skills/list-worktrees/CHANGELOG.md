# list-worktrees — changelog

## Changelog

- **1.1.0** — Added a per-worktree **unlanded** count measured against the
  **local** `<base>` (`git log "$WORKFLOW_BASE_BRANCH..HEAD"`). This workflow is
  local-first (`origin/<base>` is frozen behind `/base-push`), so the relevant
  "is there work here I haven't dealt with" signal is "not yet landed in local
  base", not "not pushed to a remote" — consistent with `remove-worktree`'s
  safety gate.
