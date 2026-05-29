---
name: define-architect
description: Interactive architecture definition. Drills with the user on languages, frameworks, dependencies, databases, caching, logging, monitoring, linting, API structure, and high-level infrastructure — challenging every technology choice for fit and pitfalls. Writes `docs/architecture.md`, `docs/api-conventions.md`, `docs/best-practices.md` (plus split docs). Then scaffolds the initial code skeleton (package manifest, entrypoints, lint/formatter configs, .env stub, version pins, etc.), with subagent critical review of both docs and scaffold. Skips testing (`define-qa`) and deployment details (`define-deploy`). Owned by `define-project`.
---

# define-architect — how it's built

Interactive dialog with the user to lock down the technology stack and code-level architecture, then seed the initial code scaffold. Your role: senior architect who **challenges every technology choice** rather than rubber-stamping it.

Produces:

- `docs/architecture.md` — components, data flow, invariants, decisions log
- `docs/api-conventions.md` — only if the project exposes an API surface
- `docs/best-practices.md` — coding conventions, lint rules, patterns to repeat / avoid
- `docs/architecture/<topic>.md` — split docs when the main file grows unwieldy
- Initial code scaffold — package manifest, entrypoints, lint/format/git-hook config, language version pin (e.g., `.nvmrc`, `.python-version`, `rust-toolchain.toml`), `.env`/`.env.example` stub, `.gitignore` matched to the stack

## Re-entry detection

```bash
if [ -f docs/architecture.md ] && ! head -1 docs/architecture.md | grep -qE '^#\s*Architecture\s*$'; then
  mode="update"
else
  mode="first-run"
fi
```

In `update` mode: **start by scanning every `docs/architecture*.md` for `## Open questions`** — those bullets are areas the user previously deferred (Phase B's two-level loop records skipped areas there). Surface them first as the natural starting points: "Last time you parked these — want to tackle any now?" If none are pending, ask "what do you want to change?" with options: change a technology, add a component, document a new convention, expand a decision, restructure docs, regenerate a scaffold piece, or pick an area from Phase B's list. Jump to the relevant section.

## First-run dialog

### Phase A: technology preferences

Open with:

> "Are there specific technologies you want to use for this project — language(s), framework, database, etc. — or do you want me to suggest a stack based on the product definition?"

Three paths from the answer:

1. **User has firm preferences** — challenge them. Don't blindly accept. See "Challenging technology choices" below.
2. **User wants suggestions** — propose a stack derived from `docs/product.md` (read it!). Justify each choice in one sentence and call out the alternative you considered. User can accept / reject / amend each.
3. **Mixed** — user has some preferences; suggest the rest.

In all three cases, end Phase A with a locked-in **stack table** in `docs/architecture.md`:

```markdown
## Stack

| Layer | Choice | Version | Why |
|---|---|---|---|
| Language | ... | ... | ... |
| Framework | ... | ... | ... |
| Database | ... | ... | ... |
| Cache | ... | ... | ... |
| Logging | ... | ... | ... |
| Monitoring / metrics | ... | ... | ... |
| Alerting | ... | ... | ... |
| Lint / format | ... | ... | ... |
| Static analysis / type-check | ... | ... | ... |
| API style | ... | (n/a) | ... |
| Key libraries | ... | ... | ... |
```

If the project doesn't need a layer (e.g., a CLI tool has no database), leave the row out — don't write "n/a" everywhere.

### Phase B: drill loop — two-level control

The user controls **how deep** to go on each area AND **which areas** to cover. Same two-level shape as `define-product`'s Phase B:

**Inner loop — depth on a single area.** Pick an area. Drill with `AskUserQuestion` (2–4 questions per turn). Update the relevant doc (`architecture.md` / `api-conventions.md` / `best-practices.md`). Ask: "Want to go deeper here, or have we covered this enough?" If "deeper", surface the most underspecified follow-up and continue. If "enough", exit the inner loop.

**Outer loop — area coverage.** Once an area is "enough", surface the next one. Two ways to pick:

1. **Suggest one** — pick from the area list below based on what's least defined relative to the product description so far, framed as a recommendation.
2. **Let the user choose** — show category headings as `AskUserQuestion` options (not every sub-bullet) and ask which to tackle next.

After each area, the user can say "I want to move on" to exit the outer loop and proceed to Phases C–G. **Areas not covered are not failures** — record them as `## Open questions` entries (one bullet per skipped area, naming the area) in `docs/architecture.md` so a future `/define-architect` re-entry surfaces them as natural starting points.

The whole skill exits when the user says "done overall". Coverage of just the stack table plus 2-3 areas is fine for an MVP; re-enter later with more information.

### Critical-reviewer role — applies on every answer

The default-of-this-skill is to **challenge every technology choice and operationalize every vague claim**, regardless of which area is being drilled.

For technology choices, run each through:

- **Maturity / ecosystem** — is this tech still maintained? Hiring pool? Library availability?
- **Fit for the product** — does the product's load / data shape / latency profile actually match what this tech is good at?
- **Operational complexity** — what does the user take on by picking this? On-call burden, runtime model, version-upgrade story.
- **Lock-in** — how hard is it to move off later if the choice turns out wrong?
- **Known pitfalls** — every popular tech has a list. Surface the top 2-3 the user should know about.
- **Cheaper alternative** — would a simpler / more boring option work? (Often the answer is yes.)

Phrase pushback as questions + alternatives, not blocks. Example: "You picked Kafka for event ordering — for the throughput you described in product.md (~50 events/sec), would a plain Postgres queue cover it with a lot less ops burden? If you've used Kafka before, that may still be the right call."

For vague answers — "fast", "scalable", "secure", "modern" — push back the same way `define-product` does: operationalize the claim. "Scalable to what load?" "Secure against what attacker?" Don't write the answer down until it has a measurable / specific form.

Record every challenge + decision in the `## Decisions log` of `docs/architecture.md`, dated, newest first. Decisions log entries are how this skill avoids re-litigating the same call on re-entry.

### The area list

**★** marks the **essentials** — areas that are load-bearing for almost any backend / service / app; aim to at least *surface* these even if the user defers a deep dive. **⚙** marks **operational-discipline** areas — they look optional but quietly determine reliability; raise them early so they're not retrofitted under an outage.

Areas tagged `(originally covered)` are the only ones the prior version of this skill named; the rest are new. Coverage is treated as a menu the user orders from, not a checklist.

#### Execution shape — how the runtime actually runs

- **★ Concurrency model** — sync/blocking vs async, threads vs event loop vs coroutines; request lifecycle from accept to response
- **★ Statelessness** — what state lives in-process vs externalized; session storage; sticky vs cookie-able sessions
- **★ Process model** — single binary vs multi-service; long-running vs short-lived; what runs where
- **⚙ Graceful shutdown** — signal handling, in-flight-request draining, deadlines
- **Hot path vs cold path** — which requests are latency-critical vs background; clarifies what gets optimized

#### Data architecture (extends the original "data model" bullet)

- **★ Primary data store choice + access pattern** — OLTP vs OLAP, read-heavy vs write-heavy (originally covered as part of data model)
- **★ ID strategy** — auto-increment / UUID / ULID / Snowflake; external-facing vs internal IDs
- **★ Schema migration policy** — expand-contract pattern, backward-compat window during rolling deploys
- **★ Transaction boundaries** — what's atomic, what's eventually consistent, where the boundary lives
- **★ Idempotency** — which write paths must be safe to retry; how the guarantee is enforced
- **Search index** — separate from primary DB? sync model? eventual-consistency window?
- **File / blob storage** — upload/download flow, signed URLs, lifecycle, multipart
- **★ Caching strategy** (originally covered) — what's cached, where, with what TTL / invalidation rule, what bug class it solves
- **⚙ Background data integrity** — reconciliation jobs, repair workflows, drift detection

#### Request lifecycle + middleware

- **★ Middleware order** — auth → trace → log → rate-limit → validate → handler → response. The order is load-bearing.
- **★ AuthN strategy** — how the current user is established on every request
- **AuthZ strategy** — where the check happens, what gets checked, fail-closed vs fail-open
- **★ Timeouts** — per layer + end-to-end budget; what cascades to what
- **Retries + backoff** — caller-side strategy, jitter, circuit breakers
- **★ Rate limiting** — per-user / per-IP / per-endpoint; fair sharing
- **★ Input validation boundary** — where untrusted input is cleansed; what's trusted past that line
- **Pagination + filtering** — cursor vs offset, max page sizes, defaults
- **Bulk operations** — batch APIs, partial-failure semantics
- **Streaming** — SSE / WebSocket / gRPC stream patterns if applicable

#### Async + jobs

- **★ Background jobs** — cron vs queue vs event-driven; in-process worker vs separate process; failure handling
- **Queue / messaging** — broker choice (challenge it!), ordering guarantees, retry policy, dead-letter queues
- **Long-running tasks** — how the user is notified of completion (poll / webhook / push?)
- **Multi-process coordination** — leader election, distributed locks (most apps don't need this)

#### Boundaries + interop

- **★ Internal vs external API boundaries** — public contract vs internal; what counts as a breaking change at each
- **★ External dependencies** (originally covered) — every external service + failure mode per dep (timeout, fallback, fail-open, fail-closed)
- **API versioning** — public + internal; deprecation window
- **API contract testing** — schema-driven (OpenAPI / protobuf / etc.), codegen, compat checks
- **Encoding / serialization** — JSON vs protobuf vs msgpack; UTF-8 vs binary gotchas
- **★ Error handling philosophy** — exceptions vs result types, error wrapping, error taxonomy
- **★ API surface** (originally covered) — endpoints / RPC methods / library functions exposed externally; style (REST, GraphQL, RPC, CLI); auth model; versioning; error envelope. Writes to `docs/api-conventions.md`. Delete that file if no external API.

#### Observability

- **★ Logging conventions** (originally covered) — structured vs unstructured, log levels, what goes in / what stays out (PII!), correlation IDs
- **★ Metrics** — RED (rate / errors / duration) or USE (utilization / saturation / errors); what's instrumented at which layer
- **Distributed tracing** — span propagation, correlation IDs, sampling rate
- **★ Health checks + readiness** — liveness vs readiness; which dependencies count as "must be reachable"
- **★ Monitoring + alerting** (originally covered) — what metrics exist, what alerts fire, what dashboards a dev pulls up first when debugging
- **⚙ Debug endpoints + admin tooling** — REPL access? Runtime config inspection? Killswitches?

#### Reliability + scale patterns

- **⚙ Resource limits** — connection pools, memory caps, request-body sizes, timeouts (per layer)
- **Circuit breakers / bulkheads / fallbacks** — when each is needed (often none)
- **Multi-region / data sovereignty** — only if applicable
- **Performance discipline** — N+1 prevention rules, query budgets, cardinality limits on metrics / logs

#### Code organization + style (writes to `docs/best-practices.md`)

- **★ Code conventions** (originally covered) — every "we always do X, never do Y" rule, in `scenario + rule + how-to-apply` format
- **★ Module / package boundaries** — what can depend on what (the import graph as policy)
- **Monorepo vs polyrepo** — if it's a decision to make
- **★ Error-handling style at the code level** — paired with the philosophy above
- **Naming conventions** — for the code units the team writes most often
- **ADRs** (architecture decision records) — where they live, when one is required

#### Build + dependencies + dev loop

- **★ Linting / static analysis / type-checking** (originally covered) — what tools, what rule set, what's enforced by CI vs hooks
- **★ Reproducibility** — lockfiles, pinned base images, deterministic builds
- **⚙ Dependency-update policy** — automation, security-update SLA, supply-chain hygiene
- **Build system specifics** — incremental, cached, what runs in CI vs locally
- **★ Local dev experience** — how the project runs on a laptop, hot reload, fixtures, seed data, mocks

#### Configuration + cross-cutting policy

- **★ Configuration** (originally covered) — env vars / file / secrets manager; required vs optional; per-environment vs global
- **Feature flags** — runtime config, rollout mechanism, kill-switch semantics
- **Audit / event sourcing** — append-only logs, replay capability (only when relevant)
- **Crypto hygiene at architecture level** — password hashing choice, signing, encryption-at-rest expectations (high-level — full threat model lives in `define-deploy`)

#### Components + flow

- **★ Component decomposition** (originally covered) — what code units exist and what each owns. Writes to `## Components` in `docs/architecture.md`.
- **★ Data flow** (originally covered) — how a request / event / job moves through the components. Diagram or numbered list.
- **★ High-level infrastructure** (originally covered) — where the code runs (containers, serverless, VMs). Just the topology — `define-deploy` covers details.

### How to surface the list to the user

Don't dump the whole tree at once. When asking the user "which area next?":

1. If you have a strong recommendation (essentials they haven't touched, especially anything load-bearing for what `docs/product.md` says the product is), lead with: "I'd suggest <area> next — <one-sentence why>."
2. Show the **category headings** as `AskUserQuestion` options plus an "Other" / free-form fallback. Once they pick a category, list bullets *inside* that category for the next selection (or pick the most essential one inside it and ask if they want that or something else).
3. Always offer "I'm done overall" as an option in the outer loop.

## Phase C: splitting architecture.md

If a section grows past ~300 lines, split it into `docs/architecture/<topic>.md` and link from the main file. Same boundary rule as `define-product`: natural concern boundary, not line count.

## Phase D: subagent critical review of the docs

After the user signs off on the dialog, spawn **3 subagents in parallel** (Agent tool, single message, three calls, `subagent_type: general-purpose`):

1. **Architecture critic** — read `docs/architecture.md` + any `docs/architecture/*.md`. Identify unclear / underspecified / contradictory statements, gaps between components, and stack choices that look mismatched to the product description. 400 words.
2. **Convention critic** — read `docs/best-practices.md` + `docs/api-conventions.md`. Identify rules without a clear *why*, rules that contradict, conventions the stack will force that aren't written down. 400 words.
3. **Operational critic** — read everything. Identify operational risks the docs don't address (how do you deploy a fix at 3am? what fails if the database is down? what's the failure mode of each external dep?). 400 words.

Consolidate findings, present to user. Decide per-finding: drill back, defer as `## Open questions`, or reject. Loop until clean.

## Phase E: code scaffold

Once docs are signed off, generate the initial code skeleton **specific to the chosen stack**. Don't write business logic — write structure.

### What to seed (stack-dependent — adapt)

The exact files differ by stack. Typical seeds for the common stacks:

#### Node.js / TypeScript

- `package.json` with name, version, scripts, dependencies
- `.nvmrc` with the Node version
- `tsconfig.json` (if TypeScript) — matches stack table's TS version
- `.eslintrc.*` / `.prettierrc.*` matched to the lint tools chosen
- `.editorconfig`
- `.gitignore` from the appropriate template
- `.npmrc` if package-manager-specific
- `src/<entrypoint>.{ts,js}` — minimal "hello world"-equivalent for the framework (e.g., one Express route, one Fastify handler, one CLI command)
- `.env.example` with every config variable from the docs, each with a comment
- `husky` / `lefthook` / git-hook config if conventions call for it

#### Python

- `pyproject.toml` (Poetry / uv / hatch — whatever the user picked)
- `.python-version`
- `ruff.toml` / `.flake8` / `mypy.ini` etc.
- `src/<package>/__init__.py`, `src/<package>/main.py`
- `.env.example`
- `.gitignore`

#### Go

- `go.mod` with the module name + Go version
- `cmd/<binary>/main.go`
- `.golangci.yml`
- `.gitignore`
- `Makefile` if conventions call for one

#### Rust

- `Cargo.toml`
- `rust-toolchain.toml`
- `src/main.rs` or `src/lib.rs`
- `.gitignore`
- `rustfmt.toml`, `.clippy.toml`

Use the equivalents for whatever stack the user picked. **When in doubt, ask.** Don't invent.

### Filling in `.env.example`

Walk every config variable mentioned in `docs/architecture.md`. For each: name, one-line comment, placeholder value (`changeme` for secrets). Ask the user about variables that aren't obvious from context.

### Conventional commits / signing / hooks

If the user wants conventional-commits enforcement, sign-off requirements, or pre-commit gates, set them up here. Otherwise leave them out — don't add ceremony the user didn't ask for.

### Write workflow.config values that depend on the stack

Two `.claude/workflow.config` knobs were intentionally left commented by `/base-initialize` Phase 3 because the right values weren't knowable until the stack landed. Now they are — fill them in.

**`WORKFLOW_WORKTREE_SETUP_CMD`** — the command `/add-worktree` runs inside each new worktree to install dependencies. Derive from the package manifest you just wrote:

| Manifest written | Set the command to |
|---|---|
| `package.json` + pnpm-lock.yaml / pnpm config | `pnpm install --frozen-lockfile` |
| `package.json` + npm | `npm ci` |
| `package.json` + yarn.lock | `yarn install --frozen-lockfile` |
| `package.json` + bun.lockb | `bun install --frozen-lockfile` |
| `pyproject.toml` + Poetry | `poetry install --no-root` |
| `pyproject.toml` + uv | `uv sync` |
| `pyproject.toml` + hatch | `hatch env create` |
| `requirements.txt` | `pip install -r requirements.txt` |
| `Pipfile` | `pipenv install --deploy` |
| `Cargo.toml` | `cargo fetch` |
| `go.mod` | `go mod download` |
| `Gemfile` | `bundle install --frozen` |
| `pom.xml` | `mvn install -DskipTests` |
| `build.gradle*` | `./gradlew build -x test` |
| `mix.exs` | `mix deps.get` |
| `*.cabal` / `cabal.project` | `cabal build --dependencies-only` |
| `Package.swift` | `swift package resolve` |
| `composer.json` | `composer install --no-dev` |
| (no manifest needed, e.g. pure CLI shell scripts) | leave commented |

Write it in:

```bash
sed -i.bak "s|^# WORKFLOW_WORKTREE_SETUP_CMD=.*|WORKFLOW_WORKTREE_SETUP_CMD=\"<chosen command>\"|" .claude/workflow.config
rm -f .claude/workflow.config.bak
```

If the project is a polyglot (e.g. backend + frontend) and one install command can't cover both, write a chained command (`pnpm install && cd backend && uv sync`) or a make target (`make deps`). Ask the user first.

**`WORKFLOW_WORKTREE_COPY_FILES`** — env-shaped files that each new worktree needs but that are gitignored. Start from the `.env.example` you just wrote: the corresponding `.env` (and any siblings like `.env.local`, `.envrc`, `.env.development`) typically need copying into each worktree. Confirm the list with the user before writing:

```bash
sed -i.bak "s|^# WORKFLOW_WORKTREE_COPY_FILES=.*|WORKFLOW_WORKTREE_COPY_FILES=(\".env\" \".env.local\")|" .claude/workflow.config
rm -f .claude/workflow.config.bak
```

If the project has no gitignored env files (pure CLI tool, library with no runtime config), leave the line commented.

### Summary to user

After the scaffold is written, print a summary:

- List every file created, grouped by purpose (manifest / linter / formatter / entrypoint / config / env / ignore)
- For each non-trivial file, one-line note on what's in it and why
- Ask the user to skim and call out anything missing or wrong

## Phase F: subagent critical review of the scaffold

Spawn **3 subagents in parallel**:

1. **Scaffold completeness critic** — list every file you'd expect in a project of this stack that's missing. 400 words.
2. **Scaffold correctness critic** — read every generated file. List configurations that look wrong, versions that don't pin, defaults that are unsafe for production. 400 words.
3. **Convention-alignment critic** — read `docs/best-practices.md` + the scaffold. List places the scaffold contradicts the documented conventions. 400 words.

Present findings, decide per-finding, iterate. Loop until clean.

## Phase G: signoff

`AskUserQuestion`:

- **Sign off and continue to `define-qa`** (recommended)
- **One more dialog pass**
- **One more scaffold review pass**

Return control to `define-project`.

## Update mode (re-entry)

When `mode="update"`:

- "What do you want to change?" → route into the relevant phase
- A stack change cascades: warn the user that swapping (e.g.) the database forces regenerating scaffold + reviewing best-practices.md
- Always end with the relevant Phase D/F review + Phase G signoff

## What this skill will NOT do

- Ask about testing — that's `define-qa`.
- Spec out deployment infrastructure — `define-deploy`.
- Write business logic. Scaffold ≠ implementation.
- Accept a technology choice without challenging it at least once.
- Pin a package version it isn't reasonably confident exists (when unsure, ask the user or look it up — never invent versions).

## Companion skills

- `define-project` — the orchestrator that calls this.
- `define-product` — the previous stage; its `docs/product.md` is read-only input here.
- `define-qa` — the next stage; consumes the stack table to pick a test framework.
- `define-deploy` — later; consumes `## High-level infrastructure` as its starting point.
