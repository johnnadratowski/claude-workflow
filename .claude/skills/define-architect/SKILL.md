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

In `update` mode: ask "what do you want to change?" — options include change technology, add component, document new convention, expand a decision, restructure docs, regenerate scaffold piece. Jump into the relevant section.

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

### Phase B: drill loop

Same drill-down pattern as `define-product`'s Phase B, but for architecture. Pick the **most underspecified area** each turn and ask 2–4 targeted questions.

Areas to cover, in roughly the order most projects need:

- **Component decomposition** — what code units exist and what each owns. Write them into `## Components` in `docs/architecture.md`.
- **Data flow** — how a request / event / job moves through the components. Diagram or numbered list.
- **External dependencies** — every external service the code talks to, and what happens if each is unavailable.
- **Data model** — entities, relationships, ownership of writes. (High-level — schema details belong in code, not docs.)
- **Caching strategy** — what's cached, where, with what TTL/invalidation rule, and the *bug class* it's solving.
- **Configuration** — how config is loaded (env vars, file, secrets manager). What's required vs optional. What's per-environment vs global.
- **Logging conventions** — structured vs unstructured, log levels, what goes in / what stays out (PII!), correlation IDs.
- **Monitoring + alerting** — what metrics exist, what alerts fire on what, what dashboards a developer pulls up first when debugging. (High level — full deploy details go in `define-deploy`.)
- **Linting / static analysis / type-checking** — what tools, what rule set, what's enforced by CI vs hooks.
- **API surface (if any)** — endpoints / RPC methods / library functions exposed externally. Style (REST, GraphQL, RPC, CLI). Auth model. Versioning. Error envelope. → write to `docs/api-conventions.md`. If no external API, delete the file.
- **Code conventions** — every "we always do X, never do Y" rule. → write to `docs/best-practices.md` in the `scenario + rule + how-to-apply` format the file already prescribes.
- **High-level infrastructure** — where the code runs (containers, serverless, VMs). Just the topology — `define-deploy` covers the details.

After each area, write to the appropriate doc, show the diff, confirm.

### Challenging technology choices

This is the load-bearing part of this skill. The user is the decision-maker, but you push back. For every choice, run through:

- **Maturity / ecosystem** — is this tech still maintained? Hiring pool? Library availability?
- **Fit for the product** — does the product's load / data shape / latency profile actually match what this tech is good at?
- **Operational complexity** — what does the user take on by picking this? On-call burden, runtime model, version-upgrade story.
- **Lock-in** — how hard is it to move off later if the choice turns out wrong?
- **Known pitfalls** — every popular tech has a list. Surface the top 2-3 the user should know about.
- **Cheaper alternative** — would a simpler / more boring option work? (Often the answer is yes.)

Phrase pushback as questions + alternatives, not blocks. Example: "You picked Kafka for event ordering — for the throughput you described in product.md (~50 events/sec), would a plain Postgres queue cover it with a lot less ops burden? If you've used Kafka before, that may still be the right call."

Record every challenge + decision in the `## Decisions log` of `docs/architecture.md`, dated, newest first.

### Drilling on unclear answers

Same rule as `define-product`: "fast", "scalable", "secure", "modern" — all need to be operationalized. "Scalable to what?" "Secure against what?" Don't write the answer down until it has a measurable / specific form.

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
