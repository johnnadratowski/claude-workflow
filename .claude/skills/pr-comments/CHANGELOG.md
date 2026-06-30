# pr-comments — changelog

## Changelog

- **1.5.0** — A reply that cites a fix now **links the diff, not just the hash**: keep the
  commit SHA and add a direct commit-diff link (`…/commit/<sha>`, anchored to the file/line
  — `#diff-<sha256(path)>R<n>` — when the comment is LOC-specific) so the reviewer jumps to
  the exact change. Applies in the draft (visible in the Monocle review) and the posted
  reply. (User request.)
- **1.4.0** — Phase-4 drafts are now presented **in Monocle as one artifact per response**
  (stable id `pr-<n>-reply-<root-comment-id>`), each **prefaced with the original comment +
  its LOC** (`<path>:<line>`, omitted when not LOC-anchored) above the exact text that will
  post — so the user reviews every reply before phase 7 posts. Blocks on the verdict; the
  fix diff is reviewed natively alongside (`set_base_ref` if committed). Engine down ⇒ the
  combined-markdown-file fallback. (User request.)
- **1.3.0** — Any review routed through Monocle during a round (the fix diff in phase 5,
  or the phase-6 package audit) follows the `monocle-review` **blocking default — send
  AND wait for the verdict**, never fire-and-forget; already-committed fixes are reviewed
  via `set_base_ref`, not a raw diff artifact. (DX dogfood — agents were fire-and-forgetting.)

- **1.2.0** — Agent-posted comments now also carry a **visible** author tag at the
  **start** of the body — `**[AGENT RESPONSE · <name> / <role>]**` (or `**[AGENT
  RESPONSE]**` when identity is unresolvable), from the new shared
  `.claude/scripts/agent-identity.sh tag`. Applies to thread replies and the
  round-summary comment (phase 7). The human-invisible `<!-- agent-authored:pr-comments
  -->` tail marker is **kept** — visible head for human transparency, invisible tail
  for machine classification. (DX-jn-8-023.)

- **1.1.0** — PR #52 dogfood upgrades (DX-8012): refutations of code/contract
  claims must **quote** the source line, not paraphrase (the one bug the package
  audit caught); new **`outdated`** disposition for comments anchored on
  since-changed code; phase-1 inventory captures each thread's **reply-anchor
  root comment id** + per-comment authorship; phase-7 **pushes the head update
  first** (cited SHAs resolve) and is **resumable** via a per-round journal;
  **reviewer-aware resolution** — phase 1 asks if a human reviewer is in the
  loop (no human → resolve wholesale; human → leave their threads, resolve only
  agent-raised+human-affirmed), with a new **agent-authored marker** on every
  post so rounds can classify thread authorship; the draft artifact now embeds
  **prior comments + code links** as a per-thread preamble. `--resolve` flag
  added alongside `--no-resolve`.
- **1.0.0** — Initial: 3-surface paginated inventory + GraphQL resolved-state,
  author-context (not authority), investigate-before-believing with refutation as a
  first-class outcome, clustered triage with unposted drafts, internal-flow
  implementation + TODO ledger linkage via /open-pr, peer package audit, atomic
  user-gated posting. (DX-8011.)
