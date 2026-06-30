# remove-worktree — changelog

## Changelog

- **1.1.0** — Local-base safety gate: the "unsaved work" check now compares
  against the **local** `<base>` (`$WORKFLOW_BASE_BRANCH`) via
  `git log "$WORKFLOW_BASE_BRANCH..HEAD"` ("unlanded" commits) — this workflow is
  local-first (`origin/<base>` is frozen behind `/base-push`), so a "not on any
  remote" test would false-fire on every clean teardown. Branch-delete now also
  tests merged-into **local** base (no `git fetch`). Added a **detached-HEAD
  rescue ref**: a detached worktree with unlanded commits gets a
  `wt-rescue-<name>-<shortsha>` branch stamped at its HEAD SHA before a `--force`
  removal (orphaned commits would otherwise be lost at the next `gc`), the
  removal is gated on that ref actually existing, and `--no-rescue` opts out.
