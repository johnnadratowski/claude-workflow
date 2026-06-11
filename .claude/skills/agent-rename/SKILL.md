---
name: agent-rename
description: Rename this Claude agent everywhere — registry file, tmux pane title, tmux window name, AND Claude session name (via the built-in `/rename`). Use when the default name (current git branch at startup) isn't meaningful enough, or to disambiguate two agents on the same branch.
---

# agent-rename — rename this agent

```bash
.claude/scripts/agent-rename.sh <new-name>
```

## Effects

- Renames `~/.claude/running-agents/<old>.<pid>` to `~/.claude/running-agents/<new>.<pid>`.
- Renames the local git branch — tries the agent's recorded base branch first (from `~/.claude/agents/<old>`) via `git branch -m <base> <new>`; if no base recorded, falls back to renaming the currently-checked-out branch. Failures (branch already exists, checked out elsewhere) are reported but don't abort the rename of the agent identity.
- Moves the persistent base-branch file `~/.claude/agents/<old>` to `~/.claude/agents/<new>` and writes the new name into it. This is what the SessionStart hook uses to warn about "wrong branch" drift on future restarts.
- Sets the current tmux **pane title** to `<new-name>` (right granularity when two Claudes share a window via splits). Pane titles show in the pane border if you've set `pane-border-status top|bottom` — turn it on with `tmux set -g pane-border-status top` if you want to see them.
- Also renames the tmux **window** to `<new-name>` and disables tmux's automatic-rename so the name sticks (foreground-process tracking otherwise clobbers it). On a split-pane window, this means the window name tracks whichever pane renamed most recently — pane titles are the source of truth.
- Types `/rename <new-name>` + Enter into the current pane so Claude's own session name updates too (shown in the prompt box, `/resume` picker, and terminal title).
- Removes any prior `<new-name>.*` entries to honor the overwrite policy.

## Constraints

- `<new-name>` is sanitized: alphanumerics, dashes, and underscores. Slashes and other chars collapse to dashes. Empty after sanitization → error.
- Must run inside tmux; otherwise the agent has no identity to rename.

## Examples

```bash
# Make a more descriptive name than the branch
.claude/scripts/agent-rename.sh researcher

# Disambiguate two agents on the same branch
.claude/scripts/agent-rename.sh main-coder
.claude/scripts/agent-rename.sh main-reviewer
```
