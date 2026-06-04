# TODOs

Tracked work lives as **one file per TODO** under this directory, driven by the
`/todo` skill. The published index at [`../TODO.md`](../TODO.md) is **generated** —
never hand-edit it; run `node .claude/scripts/gen-todos.mjs` (the `/todo` skill
does this for you) and the CI drift-guard re-runs it.

- **Active TODOs:** `docs/todos/<ID>.md`
- **Closed TODOs:** moved (never deleted) to `docs/todos/completed/<ID>.md`
- **Taxonomy:** `milestones.json` (areas→prefix, priorities, statuses, milestones)

## Frontmatter shape

```markdown
---
id: FEAT-001            # immutable; AREA-<lane>NNN (lane from your worktree; 0 if un-laned)
title: Imperative title
status: open            # open|in-progress|blocked|deferred|done|cancelled
priority: medium        # critical|high|medium|low
area: feature           # must match a key in milestones.json; prefix must match the id
milestone: backlog      # must match a milestones.json key
created: 2026-01-01      # ISO date, set once
updated: 2026-01-01      # bumped on every change
tags: []
blocked_by: []          # [other-ids] — must resolve to real TODOs

# added on close:
# completed: 2026-01-02
# commits: [<sha>, ...]
---

One-paragraph description of the work (the first line becomes the index "hook").
```

See the `/todo` skill (`.claude/skills/todo/SKILL.md`) for the full lifecycle.
