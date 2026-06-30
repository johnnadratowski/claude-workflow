# TODO system internals

Reference detail for the file-per-TODO system that the `/todo` skill
(`.claude/skills/todo/SKILL.md`) factors out: the full **ID-allocation algorithm**
and the **generator-managed cross-link / Jekyll** mechanics. The skill keeps the
operational verbs and one-line pointers here; this doc is the deep reference, reread
only when you change the ID scheme or the link generation.

## ID allocation

`AREA-<NS>-<lane>-NNN`: the area's prefix from `milestones.json` (`SEC`, `MON`, `SRV`,
`UI`, `INF`, `CMP`, `FEAT`, `DX`) + a **per-engineer namespace** `<NS>` + **this
worktree's lane number** + a zero-padded 3-digit sequence — **each its own dash-delimited
segment**, scoped per (area, NS, lane). Example: `SEC-jn-8-001` (namespace `jn`, lane 8,
sequence 001).

> **Why the lane is its own segment.** It used to be concatenated onto the sequence
> (`SEC-jn-8001`), which aliases once lanes reach two digits: an end-unanchored scan for
> lane 1 (`…-1[0-9]{3}`) also matched lane 10's `…-10001`. The dash makes the lane
> unambiguous from the sequence at ANY width — `jn-1-` ≠ `jn-10-` ≠ `jn-100-`. (DX-jn-8-006.)

**Two namespacing axes, both needed:**
- **`<NS>` (per-engineer)** guards against collisions *across clones* — a second engineer
  (e.g. Patrick) mints on their own machine with no shared lock, so without a per-engineer
  namespace their `SEC-0001` would collide with ours and a TODO could be lost on merge.
- **`<lane>` (per-worktree)** guards against collisions *within one engineer's machine* —
  parallel worktrees all share one git identity (so the same `<NS>`), and mint in parallel
  with no lock; the lane keeps them disjoint (this is the original DX-003 fix). NS does not
  subsume the lane, nor vice-versa.

**Step 1 — namespace `NS`:** resolved by `_config.sh` as `WORKFLOW_TODO_NS`. Precedence:
the explicit per-clone knob (**recommended** — set `WORKFLOW_TODO_NS` in the gitignored
`.claude/workflow.config.local`, e.g. `WORKFLOW_TODO_NS="jn"`) → else the full local-part
of `git config user.email` (lowercased, alnum-only — collision-safe but long, so most
engineers set the short knob) → else `0`.

```bash
ROOT=$(git rev-parse --show-toplevel)
source "$ROOT/.claude/scripts/_config.sh"     # exports WORKFLOW_TODO_NS
NS="$WORKFLOW_TODO_NS"
```

**Step 2 — lane number:** look up the current worktree's path in
`~/.config/goals-worktrees.json` (`worktrees[].path` → `lane`). **If not found, use `0`.**

```bash
LANE=$(python3 -c "import json; d=json.load(open('$HOME/.config/goals-worktrees.json')); print(next((w['lane'] for w in d['worktrees'] if w['path']=='$ROOT'), 0))" 2>/dev/null || echo 0)
```

**Step 3 — next sequence:** scan existing IDs across BOTH `docs/todos/` and
`docs/todos/completed/` for that prefix **and this NS and lane**, take `max + 1` (start
`001`). The scan is **end-anchored** and accepts both the new dash form and any legacy
concatenated id for the same lane (`-?` = optional lane dash), so the sequence stays
continuous across the format change and a one-digit lane never grabs a two-digit lane's ids:

```bash
PREFIX=SEC   # the area's prefix from milestones.json (SEC, MON, DX, …)
last=$(ls docs/todos docs/todos/completed 2>/dev/null \
  | sed 's/\.md$//' \
  | grep -oE "^${PREFIX}-${NS}-${LANE}-?[0-9]{3}$" \   # anchored: lane 8 ≠ lane 80; `-?` spans old+new
  | grep -oE '[0-9]{3}$' | sort -n | tail -1)          # the 3-digit seq is always the last group
NEXT=$(printf '%03d' $(( 10#${last:-000} + 1 )))        # 10# forces base-10 (ignore leading-zero octal)
# mint:  ${PREFIX}-${NS}-${LANE}-${NEXT}   →  e.g. DX-jn-8-006 (none yet ⇒ ${PREFIX}-${NS}-${LANE}-001)
```

So engineer `jn` in lane 8 mints `DX-jn-8-006`; lane 10 mints `SEC-jn-10-001`; engineer `pk`
in lane 0 mints `SEC-pk-0-001` — never the same string as `jn`'s, across machines OR
worktrees, **at any lane width**.

**Legacy IDs grandfather** — bare `AREA-NNN` (`SEC-002`), legacy lane-concatenated
`AREA-<lane>NNN` (`DX-8011`), and the prior NS-concatenated `AREA-<NS>-<lane>NNN`
(`DX-jn-8001`) all stay valid and untouched. `ID_RE`
(`/^[A-Z]+-([a-z0-9]+-)?(\d+-)?\d{3,}$/`) accepts every form: the optional `(\d+-)?` is the
new lane segment, and when it's absent the `\d{3,}` tail absorbs an old concatenated
lane+seq. Step 3's `-?` reads max-seq across old and new forms for a lane, so the sequence
continues unbroken (lane 8's `DX-jn-8001..8005` → next `DX-jn-8-006`). **Never renumber an
existing ID.**

IDs are **immutable** — deferring, blocking, or re-scoping a TODO never changes its
ID, so commit references stay valid forever. (Milestone/priority are mutable fields.)

## Cross-links (generator-managed)

**Cross-links are generator-managed — never hand-write them.** `pnpm gen:todos`
owns both directions and is idempotent:

- **Forward** — every ID in `docs/TODO.md` (active + completed) links to its
  RENDERED page with a **relative** `.html` path: `todos/<ID>.html` (active) or
  `todos/completed/<ID>.html` (closed).
- **Back** — the generator injects the `gen:todos:backlink` block (between the
  managed-comment markers shown in the skill's frontmatter example) at the top of
  every TODO body, stripping and re-adding it on each run. Do **not** edit or remove
  it by hand; write your TODO body below it and let the generator place it. The
  back-link is a **relative** path to the index: `../TODO.html` from an active file
  in `docs/todos/`, `../../TODO.html` from a closed file in `docs/todos/completed/`.
  The generator picks the right depth from each file's location and re-renders on
  every run, so a file moving to `completed/` on close self-corrects (no rot).
- **Why `.html`, and served by Jekyll?** `docs/todos/` is **included** in the
  Jekyll build and each page gets `layout: default` (a `defaults` rule in
  `docs/_config.yml`), so these `.html` links resolve on the published docs site
  (`pnpm docs:dev` / GitHub Pages) and render with the nav/chrome. Trade-off:
  `.html` targets do NOT resolve when browsing the raw `.md` files in a local
  markdown viewer or the github.com repo browser (there is no `.html` on disk) —
  the site is the priority since the docs-nav overhaul. The full rationale (and
  how to revert to `.md`, or serve both surfaces via the `jekyll-relative-links`
  plugin) is in the "Cross-links" comment block in `scripts/gen-todos.mjs`.
- CI's `drift-guards` job diffs `docs/TODO.md docs/todos`, so a missing or stale
  link (forward or back) fails the build.
