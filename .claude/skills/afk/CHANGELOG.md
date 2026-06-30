# afk — changelog

## Changelog

- **1.2.0** — **Publish-default flipped to land-local-only.** A clean run now
  lands the work into local `<base>` via `/base-merge up` by default and stops
  there — no origin touch — so the user reviews and publishes on return. The
  origin push (`/base-push`, with its non-fast-forward guard) now requires an
  explicit **`--publish`**; the old `--no-publish` flag is gone (publish was the
  default before). An unattended run no longer advances `origin/<base>` without
  being asked. Updated every surface: invocation, the flag description, the
  autonomy-contract bullet, the journal merge-policy line, the Finish clean-run
  step, and "What this skill will NOT do".
- **1.1.0** — (merge-helper hardening) Finish now lands **and** publishes through
  the base skills — `/base-push` (default) or `/base-merge up` (`--no-publish`) —
  never a hand-rolled `git push origin <base>` that skips the non-fast-forward
  guard. It **honors the `merge-helpers.sh` return codes** (`1`/`2`/`3`) and a
  non-ff push rejection: any of these is a Stop condition surfaced in the report,
  never force-pushed or blindly retried.
