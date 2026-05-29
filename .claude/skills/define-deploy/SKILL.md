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

In `update` mode: ask "deployment, security, or both?" then "what do you want to change?"

## First-run dialog — Part 1: deployment

### Phase A: high-level deployment shape

`AskUserQuestion`:

> "How do you want to deploy this — do you have a specific platform in mind (Fly, Vercel, AWS ECS, Kubernetes, bare-metal, etc.), or want a suggestion?"

If the user wants a suggestion, propose one matched to:
- The stack from `docs/architecture.md`
- The product's scale + uptime needs from `docs/product.md`
- The user's team size + ops experience (ask if not obvious)

Boring wins. Don't suggest Kubernetes for a single-service web app that gets 100 RPM.

### Phase B: drill loop

Walk these areas in order. Each one: 2-4 questions → write to `docs/deployment.md` → confirm.

- **Environments** — what envs exist (local / dev / staging / prod / preview) and what's the same vs different about each.
- **Build pipeline** — what triggers a build, what artifacts come out, where they're stored.
- **Release flow** — what triggers a deploy, who/what approves it, manual vs automated, ramp speed.
- **Rollback** — how. How fast. Who can do it. **If the user says "we'll figure it out" — STOP. Press until there's an answer.** Rollback is the single most common gap.
- **Secrets management** — where secrets live in each env, how the running code reads them, rotation policy. Cross-reference `docs/security.md`.
- **Config management** — env vars vs config files vs runtime config service. How config changes ship to a running process.
- **Database migrations** — when, how, who decides. Backward-compat rules during a rolling deploy. (Big bug source — get this written down.)
- **Observability in prod** — what dashboards a dev opens at 3am. What alerts fire to whom. What's the on-call rotation.
- **SLOs / SLIs** — if the project has any. Don't invent ones the user won't enforce.
- **Cost** — is anything in the architecture cost-asymmetric (e.g. a query that 100xes spend under load)? Write the watchlist.
- **Disaster recovery** — what's backed up, RPO, RTO, how a restore actually happens. Test cadence.

### Critical-reviewer mode

For each answer, run the same checks:

- "We'll handle that later" — push back. Surface the specific risk if left unhandled.
- Conflicts with the architecture (e.g. user picked stateless container deploy but architecture stores files locally) — flag it.
- Single point of failure with no mitigation — flag it.
- Vague terms — operationalize. "Auto-scales" → on what signal, with what bounds, how fast.

## First-run dialog — Part 2: security

### Phase C: threat model

`AskUserQuestion`:

> "What does this product handle that needs to be protected, and from whom?"

Walk the asset classes:
- User data (PII, PHI, financial, etc.)
- Authentication credentials / secrets
- Money movement / business-critical writes
- IP / proprietary content
- Availability itself (DoS targets)

For each asset class the user names: write a `## Threat model — <asset>` section in `docs/security.md` containing the asset, attacker capability assumed, and the boundary. Same format the existing template prescribes.

If the user says "none of those apply" — challenge it. A pure CLI tool that ships to other engineers still has supply-chain concerns. Almost nothing is genuinely "no security concerns."

### Phase D: sensitive-operation rules

For each threat-model asset, ask: "What rule should every code path that touches this follow?" Distill into the `scenario + rule + how-to-apply` format the existing security.md template requires.

Drill on common gaps the user often hasn't covered:

- AuthN/Z — how is the current user established on every request, how is authorization checked, where can it be bypassed.
- Input validation boundary — what's trusted, what isn't, where the cleansing happens.
- Logging hygiene — what's NEVER logged (cross-reference `docs/architecture.md`'s logging conventions).
- Outbound calls — what external services the code talks to, how creds are scoped.
- Dependency management — how / how often dependencies are updated; what triggers an out-of-band update.
- Data retention + deletion — what the user can ask to be deleted, how long it takes, what's actually purged vs marked.

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

- "Deployment, security, or both?" → "what do you want to change?"
- Architecture changes (from `define-architect` update mode) often invalidate parts of this — when the user re-enters here after an arch change, flag what likely needs revisiting.
- Always end with Phase F review + Phase G signoff.

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
