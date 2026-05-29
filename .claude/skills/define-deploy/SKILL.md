---
name: define-deploy
description: Interactive deployment + security definition. Drills with the user on how the project is built, packaged, released, rolled back, monitored in prod, what threats it must defend against, and what sensitive data it handles. Writes `docs/deployment.md` and `docs/security.md` (plus split docs for non-trivial topics). Spawns subagent critics. Owned by `define-project`; runs after `define-qa` and before `define-tickets`. No code scaffold here — deployment artifacts (Dockerfile, CI workflows) are owned by this skill and seeded as part of Phase E.
---

# define-deploy — how it's shipped + what it must defend against

Interactive dialog with the user covering deployment AND security in one stage. Your role: SRE + security engineer who **doesn't let "we'll figure it out later" pass for either domain**.

Produces:

- `docs/deployment.md` — build → release → rollback flow, environments, owners, runbooks
- `docs/security.md` — threat model + sensitive-operation rules (the existing template format)
- `docs/deployment/<topic>.md`, `docs/security/<topic>.md` — split docs as topics expand
- Deployment artifacts where applicable: `Dockerfile`, `.dockerignore`, CI workflow YAML, deployment-target config (e.g. `fly.toml`, `app.yaml`, `vercel.json`), Terraform stub if the user is using IaC

## Re-entry detection

```bash
if [ -f docs/deployment.md ] || \
   ( [ -f docs/security.md ] && ! head -1 docs/security.md | grep -qE '^#\s*Security\s*$' ); then
  mode="update"
else
  mode="first-run"
fi
```

In `update` mode: **start by scanning every `docs/deployment*.md` and `docs/security*.md` for `## Open questions`** — those bullets are areas the user previously deferred (Phase B's two-level loop records skipped areas there). Surface them first as natural starting points: "Last time you parked these — want to tackle any now?" Group them by domain (deployment vs security) so the user can pick one or the other. If none are pending, ask "deployment, security, or both?" then "what do you want to change?" — options include any area from Phase B's menu plus "change platform", "expand a threat", "regenerate a deployment artifact", "restructure docs". Architecture changes (from `define-architect` update mode) often invalidate parts of this — when re-entered after an architecture update, flag what likely needs revisiting.

## First-run dialog

This stage covers **two domains in one skill** — deployment and security. They share an interview because every security decision constrains deploys (and vice versa). The structure is:

- **Phase A** — high-level framing on BOTH domains (deployment shape + initial threat-model assets) so the area-list recommendations later have something to anchor on.
- **Phase B** — unified two-level drill loop. Areas span deployment + security; the user moves between them freely.

### Phase A: high-level framing (both domains)

Two `AskUserQuestion` calls back-to-back:

> "How do you want to deploy this — do you have a specific platform in mind (Fly, Vercel, AWS ECS, Kubernetes, bare-metal, etc.), or want a suggestion?"

> "What does this product handle that needs to be protected, and from whom? Pick all asset classes that apply."

For deployment, if the user wants a suggestion, propose one matched to:
- The stack from `docs/architecture.md`
- The product's scale + uptime needs from `docs/product.md`
- The user's team size + ops experience (ask if not obvious)

**Boring wins.** Don't suggest Kubernetes for a single-service web app that gets 100 RPM.

For the security framing, present multi-select asset classes:
- User data (PII, PHI, financial)
- Authentication credentials / secrets
- Money movement / business-critical writes
- IP / proprietary content
- Availability itself (DoS targets)

For each asset class picked, write a stub `## Threat model — <asset>` section in `docs/security.md` (asset, attacker capability assumed, boundary). The deeper drill happens later in Phase B's "Threat model + sensitive ops" category.

If the user says "none of those apply" — challenge it. A pure CLI tool still has supply-chain concerns. Almost nothing is genuinely "no security concerns."

### Phase B: two-level drill loop

Same shape as `define-product` / `define-architect` / `define-qa`.

**Inner loop — depth on a single area.** Pick an area. Drill with `AskUserQuestion` (2–4 questions per turn). Write to `docs/deployment.md` or `docs/security.md` (whichever owns the area; some areas cross-reference both). Ask: "Want to go deeper here, or have we covered this enough?" If "deeper", surface the most underspecified follow-up. If "enough", exit.

**Outer loop — area coverage.** Once an area is "enough", surface the next one. The user can move freely between deployment and security areas — don't force "finish all of Part 1 before Part 2". Either suggest one (lead with the highest-value missing essential, weighted toward deployment if security is empty and vice versa so neither domain is neglected) or present the category headings via `AskUserQuestion`. Always offer "I'm done overall" as an option.

**Areas not covered are not failures** — record them as `## Open questions` entries in the appropriate doc (deployment areas go to `docs/deployment.md`, security areas to `docs/security.md`) so a future `/define-deploy` re-entry surfaces them as natural starting points.

### Critical-reviewer role — applies on every answer

For each answer, push back on:

- **"We'll handle that later"** — surface the specific risk if left unhandled. Especially load-bearing for **rollback**, **db-migration safety**, and **secrets rotation** — the three areas teams most commonly defer and then regret.
- **Conflicts with the architecture** — e.g. user picked stateless container deploy but architecture stores files locally → flag it.
- **Single point of failure with no mitigation** — flag it.
- **Vague terms** — operationalize. "Auto-scales" → on what signal, with what bounds, how fast. "Secure" → against what attacker, with what capability?
- **"None of those apply" on a security area** — almost always wrong. Push back at least once.

Don't write a vague answer down — drill it down or record it as an `## Open questions` bullet to revisit.

### The area list

**★** marks the **essentials** — load-bearing for almost any deployed system. **⚙** marks **operational-discipline** areas — they look optional but quietly determine what breaks at 3am.

Areas tagged `(originally covered)` are the only ones the prior version of this skill named; the rest are new.

---

#### PART 1 — DEPLOYMENT areas (write to `docs/deployment.md`)

#### Environments

- **★ Environments** (originally covered) — what envs exist (local / dev / staging / prod / preview) and what's the same vs different
- **★ Environment parity** — what's *genuinely* the same as prod vs different. Be honest. A diverged staging is worse than no staging.
- **★ Preview / ephemeral envs** — per-PR? Per-branch? How provisioned, scoped, torn down?
- **Production-like data** — anonymized prod data in lower envs? Synthetic? Snapshot age?
- **⚙ Cost per environment** — surprising at scale

#### Build + artifacts (extends "Build pipeline")

- **★ Build pipeline** (originally covered) — what triggers a build, what artifacts come out, where they're stored
- **★ Artifact identity** — what uniquely identifies a build (git SHA + build number? semver tag?). Determines whether you can roll back to *the exact thing that was running*.
- **⚙ Reproducible builds** — same source → same artifact bytes? Or at least same artifact behavior?
- **⚙ Provenance / supply chain** — SLSA level target, signed artifacts, SBOM generation
- **Artifact retention** — how long old builds stick around (caps how far back rollback can reach)
- **Pre-build security scans** — container image scan, dependency CVE scan, secret scan — block-the-build vs warn?

#### Release strategy (extends "Release flow")

- **★ Release flow** (originally covered) — what triggers a deploy, who/what approves, manual vs automated, ramp speed
- **★ Deploy style** — recreate / rolling / blue-green / canary / shadow. Each has different rollback implications.
- **★ Canary criteria** — if canary: what signal promotes / aborts (error rate? latency? a custom metric?)
- **Traffic shaping** — % ramp schedule, abort signals, manual gates between stages
- **⚙ Deploy-vs-release decoupling** — feature flags so deploys ≠ user-visible releases; who owns the release switch
- **Multi-region deploys** — order of regions, partial-region rollback strategy

#### Rollback (extends — usually the most under-spec'd area)

- **★ Rollback** (originally covered) — how, how fast, who can do it. Press until there's an answer.
- **★ Forward-only vs rollback** — some teams forward-fix; the choice has cascading consequences (especially for migrations). Make it explicit.
- **★ Rollback granularity** — full version revert vs per-flag-flip vs per-config-key
- **★ Database rollback story** — schema migrations rarely reverse cleanly; what's the actual plan?
- **⚙ Rollback drill cadence** — when was the last time you actually rolled back successfully?

#### Database migrations (extends current)

- **★ Database migrations** (originally covered) — when, how, who decides, backward-compat rules during rolling deploy
- **★ Expand-contract enforcement** — is there a check that catches a destructive migration in a PR?
- **★ Large-table migrations** — what's the rule for an ALTER on a table with >N rows?
- **Migration owner** — who runs migrations? When in the deploy sequence? Same release as code, or separate?
- **Data backfills** — do they live in migration files? Separately? Versioned? Idempotent?
- **⚙ Migration rollback test** — every migration should be tested forward AND backward in CI

#### Configuration + secrets (extends both)

- **★ Secrets management** (originally covered) — where secrets live in each env, how the running code reads them, rotation policy
- **★ Config management** (originally covered) — env vars vs file vs runtime config service; how changes ship to a running process
- **★ Config schema** — typed schema for all env vars / config keys; validated at boot, not at first-use
- **★ Required-vs-optional config** — what does the app do at boot when a required key is missing?
- **★ Secret rotation cadence** — and the **actual runbook** to rotate without downtime
- **⚙ Secret-leak detection** — how a leaked secret is detected (git-secrets, audit-log scans)
- **Sealed-secret / GitOps secrets** — if applicable
- **Config diff visibility** — who knows when prod config changed, and how

#### Observability + on-call (extends "Observability in prod")

- **★ Observability in prod** (originally covered) — dashboards a dev opens at 3am, alerts that fire, on-call rotation
- **★ Golden signals** — RED or USE per service, owner, alert threshold, alert action
- **★ Runbook per alert** — every alert has a runbook URL in its message, or the alert is broken. (One of the most common silent gaps.)
- **Distributed tracing in prod** — propagation, sampling rate, retention window
- **Log retention** — how long, what's archived, what's searchable in <5s
- **⚙ Alert fatigue audit** — periodic review: which alerts fired this quarter, which were actionable
- **⚙ On-call rotation** — schedule, handoff, escalation paths, comp policy
- **⚙ Postmortem culture** — when one is required, the template, the follow-up tracker

#### SLOs + error budgets (extends "SLOs / SLIs")

- **★ SLOs / SLIs** (originally covered) — only document the ones you'll enforce
- **★ The SLI** — the actual measurable behind each SLO (a query you can paste into Grafana)
- **Error budget policy** — what happens when the budget is burned (feature freeze? rollback?)
- **⚙ Customer-facing status page** — automated from SLOs, or hand-edited
- **⚙ Incident comms templates** — how customers learn something broke

#### Cost + resource limits (extends "Cost")

- **★ Cost-asymmetric paths** (originally covered) — what's the per-request cost ceiling, who watches it
- **Resource limits per service** — CPU/memory caps, autoscaling bounds
- **⚙ Spend alerts** — per-service and per-environment

#### Disaster recovery (extends current)

- **★ Disaster recovery** (originally covered) — what's backed up, RPO, RTO, how a restore actually happens, test cadence
- **★ RPO / RTO per asset class** — different assets often need different targets
- **⚙ Backup verification** — backups that don't restore are not backups; how is the chain verified?
- **Data sovereignty / residency** — where backups live, what crosses borders

#### Compliance + audit (mostly new — only if applicable)

- **Compliance posture** — SOC2 / HIPAA / PCI / GDPR / ISO 27001 — which apply, evidence cadence
- **⚙ Access review** — who has prod access, how often it's revalidated
- **⚙ Audit trail completeness** — every prod-write logged, retention bounds, tamper resistance

#### Edge / network

- **CDN** — what's cached at the edge, cache-key rules, purge mechanism
- **WAF / DDoS protection** — what's filtered, fail-mode (open or closed) under WAF outage
- **TLS termination** — at the edge or at the app? Implications for client-IP / mTLS / metrics

---

#### PART 2 — SECURITY areas (write to `docs/security.md`)

#### Threat model + sensitive operations (extends Phase A's initial framing)

For each asset class picked in Phase A, drill the threat model + sensitive-operation rules. Distill into `scenario + rule + how-to-apply` format the existing security.md template uses.

#### Identity + access

- **★ Production access model** — who can SSH/exec/query prod; via what bastion
- **★ Service-to-service authN** — mTLS / OIDC / signed tokens / shared secret
- **Tenant isolation** (if multi-tenant) — at what layer enforced, where can it be bypassed
- **Admin / impersonate flows** — who can act-as another user, with what audit trail

#### Application-layer security

- **★ AuthN / AuthZ** (originally covered) — extended: session lifetime, refresh, revocation, MFA scope
- **★ Input validation boundary** (originally covered) — extended: what's the boundary across layers (edge → app → DB)
- **★ Output encoding** — XSS / SSRF / SQLi / template-injection class — where each is contained
- **CSRF / CORS policy** — explicit, not "default"
- **★ Logging hygiene** (originally covered as "Logging hygiene") — extended: enforcement mechanism, not just policy
- **⚙ Dependency management** (originally covered) — extended: triage SLA per CVSS tier
- **⚙ Outbound calls** (originally covered) — extended: egress allow-list, credential scoping
- **★ Data retention + deletion** (originally covered) — extended: tombstoning, GDPR/CCPA delete-request handling, time-to-purge
- **Cryptography choices** — algorithms, key rotation, where keys live (KMS / HSM / file)
- **Encryption at rest** — what's encrypted, with what key hierarchy
- **Encryption in transit** — TLS version floor, internal-network policy
- **Rate-limiting as a security control** — not just for fair-sharing; for brute-force / scraping defense
- **⚙ Bug-bounty / vulnerability-disclosure policy** — even an email address counts
- **⚙ Security incident response** — who declares, who notifies, regulatory clocks

---

#### Specialized (situational — only ask if the project type calls for it)

- **Mobile-specific release** — app-store review, staged rollout via store, force-update mechanism
- **API-specific release** — versioned endpoints, deprecation notice cadence, sunset policy
- **OSS-specific release** — release notes, changelog, signing the release artifact

### How to surface the list to the user

Don't dump the whole tree at once. When asking "which area next?":

1. If you have a strong recommendation (essentials not yet touched), lead with: "I'd suggest <area> next — <one-sentence why>." Bias toward whichever domain (deployment vs security) is more empty so neither gets neglected.
2. Show **category headings** as `AskUserQuestion` options plus an "Other" / free-form fallback. Group headings under "Deployment" vs "Security" sub-labels so the user can navigate by domain.
3. Always offer "I'm done overall" as an option in the outer loop.

## Phase E: deployment + CI artifacts

Seed the build/deploy scaffold based on the choices locked in Phase A–B.

### Typical seeds (adapt to the choice)

- **Dockerfile + .dockerignore** if the project containerizes. Multi-stage if the stack benefits.
- **CI workflow file** (`.github/workflows/<name>.yml`, `.gitlab-ci.yml`, `buildkite/<name>.yml`, etc.) wiring up lint → typecheck → test → build → (optionally) deploy. Cross-reference `docs/testing.md` for the test commands.
- **Platform config** for the chosen target (`fly.toml`, `app.yaml`, `vercel.json`, `render.yaml`, etc.). Just the structural skeleton — actual values land in env vars / secrets.
- **Terraform / Pulumi stub** if the user picked IaC: one root file + provider config + a placeholder module for the main app resource.
- **Runbook files** — `docs/runbooks/<incident>.md` stubs for the top 2-3 incidents the user named (e.g. "DB CPU spike", "auth provider outage").

### Summary to user

List every file. Note the deploy flow end-to-end in one paragraph: "On push to `<base>`, CI runs `<gates>`, builds `<artifact>`, deploys to `<target>`. Rollback by `<mechanism>`."

## Phase F: subagent critical review

Spawn **4 subagents in parallel** (one more than usual — this stage has two domains):

1. **Deployment-gap critic** — read `docs/deployment.md`. List risks the docs don't cover: rollback, db-migration safety, secrets rotation, on-call gaps, cost runaway. 400 words.
2. **Security threat critic** — read `docs/product.md` + `docs/architecture.md` + `docs/security.md`. List threats / assets the security doc misses. 400 words.
3. **Architecture-vs-deploy critic** — list places where the architecture decisions in `docs/architecture.md` conflict with the deployment shape in `docs/deployment.md`. 400 words.
4. **Artifact-correctness critic** — read every Dockerfile / CI workflow / platform config the scaffold produced. List defaults that are unsafe, version drift, missing health checks, missing resource limits, missing security headers, secret leakage paths. 400 words.

Consolidate, present, iterate.

## Phase G: signoff

`AskUserQuestion`:

- **Sign off and continue to `define-tickets`** (recommended)
- **One more dialog pass on deployment**
- **One more dialog pass on security**
- **One more review pass**

Return control to `define-project`.

## Update mode (re-entry)

The routing is described in `## Re-entry detection` above (scan `## Open questions` first, fall back to "what do you want to change?"). Workflow rules that apply across every update path:

- Architecture changes (from `define-architect` update mode) often invalidate parts of this — when the user re-enters here after an arch change, flag what likely needs revisiting (typically: artifact identity, secrets management, observability dashboards, threat model).
- Always end with Phase F review (scoped to *changed* docs only) + Phase G signoff.
- A platform change (e.g. moving from Fly to AWS ECS) cascades aggressively — warn the user that most Phase B deployment areas need re-verification.

## What this skill will NOT do

- Implement actual deploy automation beyond the CI workflow stub.
- Set up cloud accounts, DNS, certificates — those are user actions; document the steps in `docs/deployment.md`.
- Provision secrets — only document where they live.
- Pen-test the application. Documentation of the threat model, not active red-teaming.

## Companion skills

- `define-project` — orchestrator.
- `define-architect` — provides the high-level infrastructure topology that this skill expands.
- `define-qa` — provides the test gates that the CI workflow wires up.
- `define-tickets` — next stage.
