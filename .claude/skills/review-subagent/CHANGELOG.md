# review-subagent — changelog

## Changelog

- **1.0.0** — (DX-jn-8-028) Initial. `/review-subagent [<target>] [--model <m>] [<ID>]`
  spawns a local Agent (background) with our review-role instructions (reads
  `agent-roles/review.md` + `base-pr` and follows them) to audit a diff/commit **read-only**
  and report GREEN / findings — a first-class reviewer alongside the fleet peer. Model resolves
  `--model` → `WORKFLOW_SUBAGENT_REVIEW_MODEL` → `sonnet` (the current Sonnet). It's the subagent arm of
  the peer-review gate's `AskUserQuestion` **Both / Only peer / Only subagent** prompt — on
  **Both**, the peer send and this skill are dispatched at the same time.
