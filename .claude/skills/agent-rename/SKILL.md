---
name: agent-rename
description: Rename this Claude agent everywhere — registry file, tmux pane title, Claude session name (via the built-in `/rename`), and the tmux window name for window-owning roles (cc/feature only; review/test share a window so their window name is left alone). Use when the default name (current git branch at startup) isn't meaningful enough, or to disambiguate two agents on the same branch.
---

# agent-rename — rename this agent

```bash
.claude/scripts/agent-rename.sh <new-name>
```

## Effects

- Renames `~/.claude/running-agents/<old>.<pid>` to `~/.claude/running-agents/<new>.<pid>`.
- Renames the local git branch — tries the agent's recorded base branch first (from `~/.claude/agents/<old>`) via `git branch -m <base> <new>`; if no base recorded, falls back to renaming the currently-checked-out branch. Failures (branch already exists, checked out elsewhere) are reported but don't abort the rename of the agent identity.
- Moves the persistent base-branch file `~/.claude/agents/<old>` to `~/.claude/agents/<new>` and writes the new name into it. This is what the SessionStart hook uses to warn about "wrong branch" drift on future restarts. **Name-keyed sidecars migrate too** — `~/.claude/agents/<old>.role` (role override) and `~/.claude/agents/<old>.cwd` (cwd→self identity for the statusline) are moved to `<new>.*`, so an override-classified agent keeps its role after the next SessionStart and the statusline shows the new name.
- Sets the current tmux **pane title** to `<new-name>` (right granularity when two Claudes share a window via splits). Pane titles show in the pane border if you've set `pane-border-status top|bottom` — turn it on with `tmux set -g pane-border-status top` if you want to see them.
- Renames the tmux **window** to `<new-name>` (and disables automatic-rename so it sticks) **only for the window-owning roles — `coordinator` (cc) and `feature`**. `review` and `test` agents are layered into a **shared** window (several panes in one), so renaming it from any one pane would clobber the label its co-tenants rely on — the window rename is **skipped** for them, and the per-pane title above is the identifier. Role comes from a `~/.claude/agents/<name>.role` override, else the name pattern (the canonical `fleet_resolve_role` in `.claude/scripts/_fleet.sh`). The same gate lives in `register-agent.sh` so a review/test agent doesn't rename the shared window at SessionStart either.
- Types `/rename <new-name>` + Enter into the current pane so Claude's own session name updates too (shown in the prompt box, `/resume` picker, and terminal title).
- Removes any prior `<new-name>.*` entries to honor the overwrite policy.

## Constraints

- `<new-name>` is sanitized: alphanumerics, dashes, and underscores. Slashes and other chars collapse to dashes. Empty after sanitization → error.
- **tmux is optional** (DX-jn-8-019): the registry / base-branch / mailbox rename works headless (identity is the cwd-based token when `$TMUX_PANE` is unset). Only the tmux pane/window title and the built-in `/rename` keystroke are skipped without tmux — the output says so.

## Examples

```bash
# Make a more descriptive name than the branch
.claude/scripts/agent-rename.sh researcher

# Disambiguate two agents on the same branch
.claude/scripts/agent-rename.sh main-coder
.claude/scripts/agent-rename.sh main-reviewer
```
