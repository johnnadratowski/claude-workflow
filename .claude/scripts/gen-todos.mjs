#!/usr/bin/env node
// Generates docs/TODO.md (the published, grouped index) from the per-TODO files
// in docs/todos/*.md, and validates every file's frontmatter against the
// canonical taxonomy in docs/todos/milestones.json.
//
//   node .claude/scripts/gen-todos.mjs           # validate + (re)write docs/TODO.md
//   node .claude/scripts/gen-todos.mjs --check   # validate only; non-zero exit on drift/error
//
// Wire `--check` (or the plain form + `git diff --exit-code docs/TODO.md docs/todos`)
// into CI so a stale index or invalid frontmatter fails the build.
//
// The /todo skill keeps docs/TODO.md live as it mutates TODOs; this generator is
// the canonical rebuild + the validator. Source of truth = the frontmatter files.
//
// No dependencies beyond Node's stdlib. Resolves the repo root by walking up from
// this script until it finds docs/todos, so it works whether it lives at
// scripts/ or .claude/scripts/.

import { readdirSync, readFileSync, writeFileSync, statSync, existsSync } from 'node:fs'
import { join, dirname, basename } from 'node:path'
import { fileURLToPath } from 'node:url'

function findRoot(start) {
  let dir = start
  for (let i = 0; i < 12; i++) {
    if (existsSync(join(dir, 'docs', 'todos'))) return dir
    const parent = dirname(dir)
    if (parent === dir) break
    dir = parent
  }
  return process.cwd()
}

const ROOT = findRoot(dirname(fileURLToPath(import.meta.url)))
const TODOS_DIR = join(ROOT, 'docs', 'todos')
const COMPLETED_DIR = join(TODOS_DIR, 'completed')
const INDEX_FILE = join(ROOT, 'docs', 'TODO.md')
const TAXONOMY_FILE = join(TODOS_DIR, 'milestones.json')

const REQUIRED = ['id', 'title', 'status', 'priority', 'area', 'milestone', 'created']
// Lane-namespaced IDs: AREA-<lane>NNN (e.g. SEC-2001 in lane 2; SEC-0001 un-laned).
// \d{3,} accepts both legacy bare 3-digit IDs (SEC-002) and the lane-prefixed form
// (4+ digits). See the /todo skill's "ID allocation" section.
const ID_RE = /^[A-Z]+-\d{3,}$/
// Array-valued frontmatter keys, written inline as `[a, b, c]`. NOTE: values are
// split on a bare comma, so an individual element must not itself contain a comma
// (fine for ids/tags/shas — the controlled vocabulary this system uses).
const ARRAY_KEYS = new Set(['tags', 'blocked_by', 'commits'])
const errors = []

// ── Minimal frontmatter parser (controlled schema: scalars + inline [a, b]) ──
function stripQuotes(s) {
  const t = s.trim()
  if ((t.startsWith('"') && t.endsWith('"')) || (t.startsWith("'") && t.endsWith("'"))) {
    return t.slice(1, -1)
  }
  return t
}
function parseValue(raw, key) {
  const v = raw.trim()
  if (ARRAY_KEYS.has(key) || (v.startsWith('[') && v.endsWith(']'))) {
    const inner = v.replace(/^\[/, '').replace(/\]$/, '').trim()
    if (!inner) return []
    return inner
      .split(',')
      .map((x) => stripQuotes(x))
      .filter((x) => x !== '')
  }
  if (v === '' || v === 'null' || v === '~') return ''
  return stripQuotes(v)
}
function parseFrontmatter(file, text) {
  if (!text.startsWith('---')) {
    errors.push(`${file}: missing frontmatter (file must start with '---')`)
    return null
  }
  const end = text.indexOf('\n---', 3)
  if (end === -1) {
    errors.push(`${file}: frontmatter not closed with '---'`)
    return null
  }
  const block = text.slice(3, end).trim()
  const body = text.slice(end + 4).replace(/^\s*\n/, '')
  const fm = {}
  for (const line of block.split('\n')) {
    if (!line.trim() || line.trim().startsWith('#')) continue
    const m = line.match(/^([a-zA-Z_]+):(.*)$/)
    if (!m) {
      errors.push(`${file}: unparseable frontmatter line: ${JSON.stringify(line)}`)
      continue
    }
    fm[m[1]] = parseValue(m[2], m[1])
  }
  return { fm, body }
}

function hook(body) {
  for (const raw of body.split('\n')) {
    const line = raw.trim()
    if (!line || line.startsWith('#') || line.startsWith('---')) continue
    const clean = line.replace(/^[-*]\s+/, '').replace(/\*\*/g, '')
    return clean.length > 160 ? clean.slice(0, 157).trimEnd() + '…' : clean
  }
  return ''
}

// ── Cross-links (index ↔ files) — RELATIVE markdown links ────────────────────
// Links point at the actual .md files on disk (NOT github.com blob URLs) so they
// resolve while browsing the markdown locally and in the GitHub repo browser.
// docs/TODO.md lives in docs/; the per-TODO files live in docs/todos/ (active)
// or docs/todos/completed/ (closed). The back-link is generator-managed and
// re-rendered on every run, so a TODO's depth is corrected automatically when it
// moves to completed/ on close (`t.archived` drives the '../' count below).

// Index (docs/TODO.md, in docs/) → a TODO file under docs/todos/[completed/]:
const todoFileUrl = (t) => `todos/${t.archived ? 'completed/' : ''}${t.fm.id}.md`
// A TODO file → the index (docs/TODO.md): one '../' from docs/todos/, two from
// docs/todos/completed/.
const indexUrlFor = (t) => `${t.archived ? '../../' : '../'}TODO.md`

// The back-link is a generator-managed block, delimited by markers so each run
// strips the old one and re-injects — re-running is idempotent, and the link is
// never hand-written (so it can't drift or rot when a file moves).
const BL_START = '<!-- gen:todos:backlink (managed — do not edit) -->'
const BL_END = '<!-- /gen:todos:backlink -->'
const escapeRe = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
const BL_RE = new RegExp(`${escapeRe(BL_START)}[\\s\\S]*?${escapeRe(BL_END)}\\n*`, 'g')
function stripBacklink(body) {
  return body.replace(BL_RE, '').replace(/^\s*\n/, '')
}
// Re-render a TODO file with a fresh back-link. The frontmatter block is sliced
// through verbatim from the raw text (never re-serialized — preserves exact
// formatting); only the back-link at the top of the body is managed.
function renderTodoFile(t) {
  const end = t.raw.indexOf('\n---', 3)
  const header = t.raw.slice(0, end + 4) // '---\n<frontmatter>\n---'
  const body = stripBacklink(t.raw.slice(end + 4).replace(/^\s*\n/, ''))
  const block = `${BL_START}\n[← Back to the TODO index](${indexUrlFor(t)})\n${BL_END}`
  return `${header}\n\n${block}\n\n${body}`.replace(/\n+$/, '\n')
}

// ── Load taxonomy ──
let taxonomy
try {
  taxonomy = JSON.parse(readFileSync(TAXONOMY_FILE, 'utf-8'))
} catch (e) {
  console.error(`FATAL: cannot read ${TAXONOMY_FILE}: ${e.message}`)
  process.exit(1)
}
const milestoneOrder = taxonomy.milestones.map((m) => m.key)
const milestoneLabel = Object.fromEntries(taxonomy.milestones.map((m) => [m.key, m.label]))
const priorityOrder = taxonomy.priorities.map((p) => p.key)
const validStatuses = new Set(taxonomy.statuses)
const areaByKey = Object.fromEntries(taxonomy.areas.map((a) => [a.key, a]))
const prefixByArea = Object.fromEntries(taxonomy.areas.map((a) => [a.key, a.prefix]))

// ── Read TODO files ──
function readDir(dir, archived) {
  let names
  try {
    names = readdirSync(dir)
  } catch {
    return []
  }
  const out = []
  for (const name of names) {
    if (!name.endsWith('.md') || name === 'README.md') continue
    const full = join(dir, name)
    if (statSync(full).isDirectory()) continue
    const raw = readFileSync(full, 'utf-8')
    const parsed = parseFrontmatter(`docs/todos/${archived ? 'completed/' : ''}${name}`, raw)
    if (parsed) out.push({ name, archived, full, raw, ...parsed })
  }
  return out
}

const active = readDir(TODOS_DIR, false)
const completed = readDir(COMPLETED_DIR, true)
const all = [...active, ...completed]

// ── Validate ──
const seenIds = new Map()
for (const t of all) {
  const fm = t.fm
  const where = `docs/todos/${t.archived ? 'completed/' : ''}${t.name}`
  for (const r of REQUIRED) {
    if (!fm[r]) errors.push(`${where}: missing required field '${r}'`)
  }
  if (fm.id) {
    if (!ID_RE.test(fm.id))
      errors.push(
        `${where}: id '${fm.id}' must match AREA-[lane]NNN (e.g. SEC-001 legacy, SEC-2001 lane-2)`,
      )
    if (seenIds.has(fm.id))
      errors.push(`${where}: duplicate id '${fm.id}' (also in ${seenIds.get(fm.id)})`)
    seenIds.set(fm.id, where)
    if (basename(t.name, '.md') !== fm.id) errors.push(`${where}: filename must be '${fm.id}.md'`)
  }
  if (fm.area && !areaByKey[fm.area]) errors.push(`${where}: unknown area '${fm.area}'`)
  if (fm.area && fm.id && prefixByArea[fm.area] && !fm.id.startsWith(prefixByArea[fm.area] + '-')) {
    errors.push(`${where}: id prefix must be '${prefixByArea[fm.area]}-' for area '${fm.area}'`)
  }
  if (fm.priority && !priorityOrder.includes(fm.priority))
    errors.push(`${where}: unknown priority '${fm.priority}'`)
  if (fm.milestone && !milestoneOrder.includes(fm.milestone))
    errors.push(`${where}: unknown milestone '${fm.milestone}'`)
  if (fm.status && !validStatuses.has(fm.status))
    errors.push(`${where}: unknown status '${fm.status}'`)
  const isClosed = fm.status === 'done' || fm.status === 'cancelled'
  if (t.archived && !isClosed)
    errors.push(`${where}: in completed/ but status is '${fm.status}' (must be done|cancelled)`)
  if (!t.archived && isClosed)
    errors.push(`${where}: status '${fm.status}' must live in docs/todos/completed/`)
  if (t.archived && !fm.completed) errors.push(`${where}: completed TODO missing 'completed' date`)
}
for (const t of all) {
  for (const dep of t.fm.blocked_by || []) {
    if (!seenIds.has(dep))
      errors.push(`docs/todos/${t.name}: blocked_by references unknown id '${dep}'`)
  }
}

if (errors.length) {
  console.error(`✗ TODO validation failed (${errors.length}):`)
  for (const e of errors) console.error(`  - ${e}`)
  process.exit(1)
}

// ── Build index ──
const byPriority = (a, b) =>
  priorityOrder.indexOf(a.fm.priority) - priorityOrder.indexOf(b.fm.priority) ||
  a.fm.id.localeCompare(b.fm.id)

const lines = []
lines.push('---', 'layout: default', 'title: TODO', '---', '')
lines.push(
  '<!-- GENERATED FILE — do not edit by hand.',
  '     Source: docs/todos/*.md frontmatter + docs/todos/milestones.json.',
  '     Regenerate: `node .claude/scripts/gen-todos.mjs` (or mutate via the /todo skill). -->',
  '',
)
lines.push('# TODO', '')
const doneCount = completed.filter((t) => t.fm.status === 'done').length
const cancelledCount = completed.filter((t) => t.fm.status === 'cancelled').length
lines.push(
  `_${active.length} active · ${doneCount} done · ${cancelledCount} cancelled. ` +
    'Grouped by milestone, then priority. Source: `docs/todos/`._',
  '',
)

for (const ms of milestoneOrder) {
  const items = active.filter((t) => t.fm.milestone === ms).sort(byPriority)
  if (!items.length) continue
  lines.push(`## ${milestoneLabel[ms]}`, '')
  for (const t of items) {
    const status = t.fm.status === 'open' ? 'open' : `**${t.fm.status}**`
    lines.push(
      `- **[${t.fm.id}](${todoFileUrl(t)})** · \`${t.fm.priority}\` · ${status} · ${t.fm.created} — ${t.fm.title}`,
    )
    // Hook + blocked-by are wrapped in spans so a docs site can render them as
    // their own lines below the title; they're plain text in raw-markdown views.
    const h = hook(stripBacklink(t.body))
    if (h) lines.push(`  <span class="todo-hook">${h}</span>`)
    if ((t.fm.blocked_by || []).length)
      lines.push(`  <span class="todo-blocked">⛔ blocked by ${t.fm.blocked_by.join(', ')}</span>`)
  }
  lines.push('')
}

lines.push('## Completed', '')
if (!completed.length) {
  lines.push('_None yet._', '')
} else {
  for (const t of completed.sort((a, b) =>
    String(b.fm.completed).localeCompare(String(a.fm.completed)),
  )) {
    const refs = (t.fm.commits || []).length ? ` (${t.fm.commits.join(', ')})` : ''
    lines.push(
      `- **[${t.fm.id}](${todoFileUrl(t)})** · ${t.fm.status} ${t.fm.completed || ''} — ${t.fm.title}${refs}`,
    )
  }
  lines.push('')
}

const output = lines.join('\n').replace(/\n+$/, '\n')

// Each TODO file with its managed back-link re-rendered (compared in --check,
// written otherwise). Skip README.md / non-TODO files — only files we parsed.
const fileRenders = all.map((t) => ({ full: t.full, want: renderTodoFile(t), have: t.raw }))

if (process.argv.includes('--check')) {
  const current = (() => {
    try {
      return readFileSync(INDEX_FILE, 'utf-8')
    } catch {
      return ''
    }
  })()
  const staleFiles = fileRenders.filter((f) => f.have !== f.want)
  if (current !== output || staleFiles.length) {
    if (current !== output)
      console.error('✗ docs/TODO.md is stale — run `node .claude/scripts/gen-todos.mjs` and commit.')
    for (const f of staleFiles)
      console.error(
        `✗ ${f.full.replace(ROOT + '/', '')}: back-link stale — run \`node .claude/scripts/gen-todos.mjs\`.`,
      )
    process.exit(1)
  }
  console.log(
    `✓ ${active.length} active, ${completed.length} completed — index + back-links in sync, frontmatter valid.`,
  )
} else {
  writeFileSync(INDEX_FILE, output)
  let rewritten = 0
  for (const f of fileRenders) {
    if (f.have !== f.want) {
      writeFileSync(f.full, f.want)
      rewritten++
    }
  }
  console.log(
    `✓ wrote docs/TODO.md — ${active.length} active, ${completed.length} completed; ` +
      `back-links synced (${rewritten} file${rewritten === 1 ? '' : 's'} updated).`,
  )
}
