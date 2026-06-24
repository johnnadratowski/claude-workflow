# Integration Notes (agent-facing)

> **Audience: agents.** This is the registry you consult **before planning or implementing**
> any code that calls an **external API, RPC, or third-party provider** — and that you keep
> current as part of that work. Keep it separate from product-facing integration docs (those
> describe *how the product uses* an integration; this describes *the provider's API contract +
> where to verify it*).
>
> **This file is a template.** Each project populates the index + per-provider entries for its
> own integrations. Seed only **verifiable** doc-source pointers; never fabricate contract
> facts — unknown operations stay marked *pending first verification*.

## The rule

When planning **or** implementing code that calls an external API/RPC/provider, **verify the
specific operations you will use** against authoritative docs — params, ordering, idempotency,
error semantics, auth, rate limits, and money-movement invariants. **Skimming is not
verification.** This is a hard requirement (wire it into your project's best-practices /
`CLAUDE.md` and the review gate).

## How to use this doc

1. **Find the provider below.** Read its **Doc sources** and the **Operations** you'll touch.
2. **Verify the specific operations** you'll call against authoritative docs.
3. **Prefer the provider's own doc tool** when one exists (a documentation **MCP** for that
   provider if available; `context7` for library/SDK docs) before manual doc-hunting.
4. **Record what you verified** here (dated) and **add any new doc location** you found to that
   provider's _Doc sources_ — in the **same diff** as your code.

### Authority & freshness

- **Cache, not authority.** Every claim cites a doc source + date. On conflict, **upstream
  docs win** — fix the note.
- **Trust window:** a finding **≤ 30 days old** may be trusted without re-fetching. Older →
  **re-verify the operations you use still match**, then re-stamp (or update).
- **Money-movement / state-mutating operations are re-verified against authoritative docs
  EVERY time**, regardless of note age. Any **contract surprise or API error** → re-verify
  immediately.

### When docs don't exist

1. Ask the user for the docs.
2. Still none → **reverse-engineer only in sandbox/testnet, never production, never
   money-moving / state-mutating endpoints.** Record dated findings below.
3. A live call against a **production** system requires **explicit user authorization** first.

### Reviewers

The review gate independently re-checks integration contracts (don't assume the implementer
got it right). A reviewer may re-verify what planning checked, must explore the docs, and
worst-case flags for a sandbox reverse-engineering pass rather than letting an unverified
money-movement call land. Reviewers also keep this doc honest (stale/over-trusted entries are
findings).

---

## Index

| Provider | Kind | Risk tier | Primary doc tool/source | Last verified |
| --- | --- | --- | --- | --- |
| _(none yet — add a row per integration)_ | | | | |

Risk tiers: **money-movement** (re-verify every time) · **infra / state-mutating** (treat as
money-movement for re-verify) · **read-only** (30-day trust window).

---

## Per-provider entry template

Copy this skeleton for each integration:

```
## <Provider>

### Doc sources   ← curated; add every newly found location here
- <provider doc MCP if one exists> — use this first
- <official docs URL / OpenAPI spec / SDK reference / changelog>

**Auth:** <how auth works>   **Risk tier:** <money-movement | infra | read-only>

### Operations we use
- `<operation>` → verified contract points (params/ordering/idempotency/errors) — verified YYYY-MM-DD
  (until verified, write: _pending first verification_)

### Learnings / gotchas
- <learning> — YYYY-MM-DD
```
