# TODO system internals

Reference detail for the file-per-TODO system that the `/todo` skill
(`.claude/skills/todo/SKILL.md`) factors out: the full **ID-allocation algorithm**
and the **generator-managed cross-link / Jekyll** mechanics. The skill keeps the
operational verbs and one-line pointers here; this doc is the deep reference, reread
only when you change the ID scheme or the link generation.

## ID allocation

`AREA-<NS>-<agentid>-NNN`: the area's prefix from `milestones.json` (`SEC`, `MON`, `SRV`,
`UI`, `INF`, `CMP`, `FEAT`, `DX`) + a **per-engineer namespace** `<NS>` + **the minting
agent's fleet id** `<agentid>` + a zero-padded 3-digit sequence — **each its own
dash-delimited segment**, scoped per (area, NS, agentid). Example: `DX-jn-cc-032` (namespace
`jn`, agent `cc`, sequence 032) or `SRV-jn-f2-001` (agent `f2`).

> **Agent id vs lane (DX-jn-8-032).** The middle segment used to be the worktree's numeric
> **lane**; it's now the agent's short **fleet id** — `cc` | `f<N>` | `pr<N>` | `test<N>`
> (from `fleet_agent_id` in `_fleet.sh`) — so an id names *which* agent minted it (`DX-jn-cc-032`
> reads better than `DX-jn-8-032`). It serves the identical collision-guard role: one unique
> value per worktree. Numeric-lane ids (`SEC-jn-8-001`) are grandfathered and never renumbered.

> **Why it's its own segment.** It used to be concatenated onto the sequence (`SEC-jn-8001`),
> which aliases once lanes reach two digits: an end-unanchored scan for lane 1 (`…-1[0-9]{3}`)
> also matched lane 10's `…-10001`. The dash makes the segment unambiguous from the sequence
> at ANY width. (DX-jn-8-006.)

**Two namespacing axes, both needed:**
- **`<NS>` (per-engineer)** guards against collisions *across clones* — a second engineer
  (e.g. Patrick) mints on their own machine with no shared lock, so without a per-engineer
  namespace their `SEC-0001` would collide with ours and a TODO could be lost on merge.
- **`<agentid>` (per-worktree)** guards against collisions *within one engineer's machine* —
  parallel worktrees all share one git identity (so the same `<NS>`), and mint in parallel
  with no lock; the per-agent id keeps them disjoint (the original DX-003 fix, formerly the
  lane). NS does not subsume it, nor vice-versa.
  > **The agent id must be UNIQUE across concurrent worktrees** — it's the collision guard, and
  > `fleet_agent_id` derives it from role + trailing number, so **same-role agents MUST have
  > distinct trailing numbers** (`john-1`/`john-2`, `john-pr`/`john-pr-2`) — two review agents
  > both named without a number would both resolve to `pr1` and could mint the same `NNN`
  > concurrently → a dup on merge (the exact DX-003 class). Unlike the numeric lane (structurally
  > unique from a project's worktree registry), this is **convention-dependent**: a fleet that can't
  > guarantee distinct role+number names should set `WORKFLOW_TODO_AGENT` to the numeric lane, or
  > leave it unset so `_config.sh` falls back to `WORKFLOW_LANE` (structurally unique per worktree).

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

**Step 2 — agent id:** `_config.sh` exports `WORKFLOW_TODO_AGENT` — this agent's fleet id
(`cc` | `f<N>` | `pr<N>` | `test<N>`) via `fleet_agent_id`, falling back to the numeric
`WORKFLOW_LANE` when self can't be resolved (headless / CI / unregistered). Either way it's a
unique per-worktree segment.

```bash
AGENT="$WORKFLOW_TODO_AGENT"   # e.g. cc, f2, pr1, test1 (fallback: the numeric lane)
```

**Step 3 — next sequence:** scan existing IDs across BOTH `docs/todos/` and
`docs/todos/completed/` for that prefix **and this NS and agent id**, take `max + 1` (start
`001`). The scan is **end-anchored** and accepts both the dash form and any legacy
concatenated id for the same segment (`-?` = optional dash), so the sequence stays continuous:

```bash
PREFIX=SEC   # the area's prefix from milestones.json (SEC, MON, DX, …)
last=$(ls docs/todos docs/todos/completed 2>/dev/null \
  | sed 's/\.md$//' \
  | grep -oE "^${PREFIX}-${NS}-${AGENT}-?[0-9]{3}$" \  # anchored per (prefix, NS, agent); `-?` spans old+new
  | grep -oE '[0-9]{3}$' | sort -n | tail -1)          # the 3-digit seq is always the last group
NEXT=$(printf '%03d' $(( 10#${last:-000} + 1 )))        # 10# forces base-10 (ignore leading-zero octal)
# mint:  ${PREFIX}-${NS}-${AGENT}-${NEXT}   →  e.g. DX-jn-cc-032 (none yet ⇒ ${PREFIX}-${NS}-${AGENT}-001)
```

So agent `cc` (engineer `jn`) mints `DX-jn-cc-032`; agent `f2` mints `SRV-jn-f2-001`; engineer
`pk`'s `pr1` mints `SEC-pk-pr1-001` — never the same string as another agent's, across machines
OR worktrees. (A numeric-lane fallback like `SEC-jn-8-001` is treated identically — it's just
another value in the same segment.)

**Legacy IDs grandfather** — bare `AREA-NNN` (`SEC-002`), lane-concatenated `AREA-<lane>NNN`
(`DX-8011`), NS-concatenated `AREA-<NS>-<lane>NNN` (`DX-jn-8001`), and numeric-lane
`AREA-<NS>-<lane>-NNN` (`DX-jn-8-030`) all stay valid and untouched. `ID_RE`
(`/^[A-Z]+-([a-z0-9]+-)?([a-z0-9]+-)?\d{3,}$/`) accepts every form: the optional second
`([a-z0-9]+-)?` is the agent-id/lane segment (now alphanumeric, so `f2`/`pr1`/`test1`/`cc`
validate alongside `8`), and when it's absent the `\d{3,}` tail absorbs an old concatenated
lane+seq. Step 3's `-?` reads max-seq across old and new forms for a segment, so the sequence
continues unbroken. **Never renumber an existing ID.**

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
