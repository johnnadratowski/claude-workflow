# base-setup — changelog

## Changelog

- **1.0.0** — (DX-jn-8-029) Initial. Per-engineer, **non-destructive** onboarding onto an
  already-configured project: creates a personal coordination base branch off `origin/master`,
  writes the gitignored `workflow.config.local` (base branch, clone path, TODO ns, optional agent
  prefix), seeds `settings.local.json`, optionally installs the user-level SessionStart hook, and
  offers skippable agent provisioning (default **1 cc + 3 feature + 2 review + 1 test** worktrees via
  `/add-worktree` + the commands to start each). Opts the clone into **fleet mode**
  (`WORKFLOW_FLEET_MODE=1`); unset base = supported solo mode. Distinct from the destructive
  new-project `base-initialize`.
