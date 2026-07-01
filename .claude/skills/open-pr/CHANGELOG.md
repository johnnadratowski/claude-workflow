# open-pr — changelog

## Changelog

- **1.9.0** — (DX-jn-8-027) **Update mode: merge the PR's base in BEFORE implementing** —
  reordered so `git merge origin/<baseRefName>` runs ahead of the change (was after). For a
  **stacked PR** `baseRefName` is the parent PR's head branch, so this merges the branch the
  PR is based on first — fixing the hard-merge when the parent changed materially. Merging
  before implementing keeps base conflicts small and unentangled from new work. (Pairs with
  the base-sync-before-plan rule codified in `agent-roles/feature.md`.)
- **1.8.0** — (DX-jn-8-026) Two additions. **(1) Update mode** (`--update <n>` / natural
  phrasing "update pr 88" / "update this pr" / "revise pr 88"): revise an **already-open**
  PR by **checking out its actual head branch first** and pushing there — the change runs
  through the normal workflow *on that branch*, so the PR updates in place. Codifies the
  hard refusal "never rebuild a PR locally and orphan its head" in `/open-pr` **and**
  `/pr-comments` — the PR #86 lesson (rebuilt locally → had to be closed). **(2)
  Commit-manifest comment**: every create (and Update push) posts a per-commit walkthrough
  comment, one line per commit with a diff link (`…/pull/<n>/commits/<oid>`), built with
  `git log --no-merges` so **merge commits are excluded** (not review units). **Create**
  lists the full PR (`<target>..HEAD`); **Update** posts a fresh per-round comment scoped to
  **only that update's new commits** (`<pre-push-head>..HEAD`). Carries the same author
  signals as other posted comments. Premise — one phase = one atomic commit so the PR reads
  commit-by-commit — is codified in `agent-roles/feature.md` (phasing is the agent's
  judgment, scaled to the work; the user can override).
- **1.7.0** — (DX-jn-8-023) Comments `/open-pr` posts now also **start with** a visible
  `**[AGENT RESPONSE · <name> / <role>]**` tag (from `agent-identity.sh tag`; falls back
  to `**[AGENT RESPONSE]**`) for human transparency, alongside the existing invisible
  `agent-authored:pr-comments` tail marker. PR body unaffected. Mirrors `/pr-comments` 1.2.0.
- **1.6.0** — (DX-jn-8-013) Always **surface the created PR's URL** as the final
  confirmation line (capture `gh pr create`'s output, echo it). The link is the
  deliverable. (No change to the frozen-`pr/*` model — confirmed correct: every PR is
  cut as a `pr/*` branch off its source, any branch can be the source, never a direct
  PR from the live base.)

- **1.5.0** — (DX-jn-8-009) Aligned with **close-before-publish**: the ledger-timing
  precondition now states the TODO is normally already closed when `/open-pr` runs, so the
  archived `completed/<ID>.md` + populated `commits:` ride inside the PR diff (not a
  follow-up sync); the in-progress/empty-`commits:` case is the documented exception.
- **1.4.0** — (DX-jn-8003) **From-source rooting is now the default.** `pr/*` is cut
  from a **source branch** (default the opening agent's current branch; name any
  branch as the first arg) and synced **up-to-date with a selectable target**
  (`--into <branch>`, default `master`); the old ledger-scoped/master-rooted mode
  is preserved as **`--scoped`**. Step 2 gains the from-source target merge (the
  scoped cherry-pick/path-split moves under `--scoped`). New Guards flag the two
  consequences: from-source + `master` target on a `<base>`-rooted branch yields a
  broad diff (use `--into <base>` for a clean feature-only diff, or `--scoped` for a
  surgical PR), and a `--into <base>` PR **advances `origin/<base>` on merge** (the
  human-gated-publish / frozen-PR interaction — surfaced, not silent).
- **1.3.0** — (DX-jn-8001) `--absorb` (step 7) now **routes `merge_into_branch_local`'s
  return code**: only on `0` does it write the ledger + delete the `pr/*` branch;
  on any non-zero it STOPS (the absorb didn't land, `<base> ⊇ <target>` not
  restored) and never deletes the frozen reviewed branch. Sources the helper from
  `.claude/scripts/merge-helpers.sh` (extracted from `base-push`).
- **1.2.0** — First end-to-end dogfood hardening (DX-8014): the `pr/*` branch is
  now cut **in place** (`git checkout -b … origin/<target>` in the caller's
  worktree, return with `git checkout "$CALLER"`) instead of a transient
  worktree — simpler, and it keeps untracked env files (`server/.env`) present
  so the pre-push hook's env-dependent gates pass (the worktree lacked them and
  failed at push). Added: `commits:`-ledger timing precondition + `--commits`/
  `git log --grep` fallback (the ledger is empty mid-work); mandatory
  **artifact regeneration after cherry-pick** before gating (a generated file
  drifts on the master-rooted branch); **gate-vs-target baseline** (a failure
  also present on `origin/<target>` is pre-existing, not this PR's); **label
  existence** handling (`gh label create` missing, or filter — body tag block is
  canonical); `pr:` back-pointer explicitly commits on the **source/base side**,
  never the frozen branch. The transient worktree remains only on `--absorb`.
- **1.1.0** — PR #52 dogfood (DX-8012): posted comments carry the shared
  `agent-authored:pr-comments` marker so `/pr-comments` rounds can classify
  thread authorship; provenance block noted as the agent-prepared record.
- **1.0.0** — Initial: frozen `pr/*` branches off the PR target, scoped-from-ledger
  (default) + `--snapshot` modes, merge-SHA → path-split rule, independent gating,
  user-gated create, TODO tagging + `pr:` back-pointer ownership, `--absorb`,
  `<base> ⊇ <target>` guards. (DX-8011 — codifies the PR #52 lessons.)
