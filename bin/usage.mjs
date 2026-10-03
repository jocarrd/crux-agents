#!/usr/bin/env node
// crux usage — which skills are really used.
//
//   crux usage [--days N] [--all]
//
// A catalog that only grows ends up getting in the way of discovery: the more
// skills there are, the worse the choice between them. This measures real use
// against the installed catalog and separates the live from the dead.
//
// The source is the agent's local transcripts. It is an internal format and
// may change; if one day it stops finding invocations, it says so instead of
// reporting zero as if it were data.

import { readFileSync, readdirSync, existsSync, statSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { homedir } from 'node:os'

const HOME = homedir()
// The projects root is not assumed: it comes from the machine's config or from
// where the kernel is installed, which always lives inside it.
function projectsRoot() {
  if (process.env.CRUX_PROJECTS_DIR) return process.env.CRUX_PROJECTS_DIR
  try {
    const cfg = readFileSync(join(homedir(), '.crux', 'config'), 'utf8')
    const m = cfg.match(/^CRUX_PROJECTS_DIR="?([^"\n]+)"?/m)
    if (m) return m[1]
    const k = cfg.match(/^CRUX_HOME="?([^"\n]+)"?/m)
    if (k) return dirname(k[1])
  } catch {}
  if (process.env.CRUX_HOME) return dirname(process.env.CRUX_HOME)
  return join(homedir(), 'Proyectos')
}

const PROJECTS = projectsRoot()
const CRUX_HOME = process.env.CRUX_HOME || join(PROJECTS, 'crux')
// CLAUDE_SKILLS_DIR is redirected by the suite and any isolated environment: if
// the transcripts still come from the real HOME, the machine is measured, not
// the sandbox.
const TRANSCRIPTS = process.env.CRUX_TRANSCRIPTS
  || (process.env.CLAUDE_SKILLS_DIR
        ? join(dirname(process.env.CLAUDE_SKILLS_DIR), 'projects')
        : join(HOME, '.claude', 'projects'))

const args = process.argv.slice(2)
const showAll = args.includes('--all')

// A value that is not a number is reported, not silently replaced by the default.
function readDays(list) {
  const i = list.findIndex(a => a === '--days' || a.startsWith('--days='))
  if (i === -1) return 90
  const raw = list[i].includes('=') ? list[i].slice('--days='.length) : list[i + 1]
  const n = Number(raw)
  if (raw === undefined || raw === '' || !Number.isFinite(n) || n <= 0) {
    console.error(`--days: '${raw ?? ''}' is not a number of days`)
    process.exit(1)
  }
  return n
}
const days = readDays(args)

function descriptionOf(dir) {
  try {
    const t = readFileSync(join(dir, 'SKILL.md'), 'utf8')
    const m = t.match(/^description:\s*([\s\S]*?)(?:\n[a-z-]+:|\n---)/m)
    return (m ? m[1] : '').toLowerCase()
  } catch { return '' }
}

const DESCRIPTIONS = new Map()

function catalog() {
  const out = new Map()
  const kernel = join(CRUX_HOME, 'skills')
  if (existsSync(kernel)) {
    for (const n of readdirSync(kernel)) {
      if (!statSync(join(kernel, n)).isDirectory()) continue
      out.set(n, 'kernel')
      DESCRIPTIONS.set(n, descriptionOf(join(kernel, n)))
    }
  }
  const projects = PROJECTS
  if (existsSync(projects)) {
    for (const p of readdirSync(projects)) {
      const dir = join(projects, p)
      if (!statSync(dir).isDirectory()) continue
      for (const sub of readdirSync(dir)) {
        if (!sub.endsWith('-docs')) continue
        const skills = join(dir, sub, '.claude', 'skills', 'project')
        if (!existsSync(skills)) continue
        for (const n of readdirSync(skills)) {
          if (!statSync(join(skills, n)).isDirectory()) continue
          out.set(n, sub.replace('-docs', ''))
          DESCRIPTIONS.set(n, descriptionOf(join(skills, n)))
        }
      }
    }
  }
  return out
}

// A skill's scripts are the other face of its use: whoever follows the
// procedure by hand runs them without calling the skill by name, and counting
// only the calls that skill comes out as dead. It happened with the quality
// gate: zero invocations while it was passed in four proposals in a row.
function catalogScripts() {
  const out = new Map()
  const kernel = join(CRUX_HOME, 'skills')
  if (!existsSync(kernel)) return out
  for (const skill of readdirSync(kernel)) {
    const dir = join(kernel, skill, 'scripts')
    if (!existsSync(dir)) continue
    for (const s of readdirSync(dir)) out.set(s, skill)
  }
  return out
}

// A script name appears in many commands that do not run it: reading it,
// copying it, searching inside. It is discarded when a reading verb precedes it.
const READ_VERB = /\b(cat|sed|awk|grep|head|tail|less|ls|wc|chmod|cp|mv|rm|find|diff|git|shellcheck|vim|nano)\s+(-\S+\s+)*\S*$/

// Writing a skill is not using it. The sessions where it is developed name its
// script over and over —heredocs that rewrite it, chmod, calibrations— and
// without this the newborn skill shows up as the most used in the catalog.
const EDITS_THE_SCRIPT = /<<\s*['"]?\w*(PY|EOF|SH)\b|chmod\s|cat\s*>|>>\s*\S|sed -i|\.replace\(/

// What a session delegates hangs under <session>/subagents/ and counts as that session.
function sessionsOf(projectDir) {
  const groups = new Map()
  const visit = (dir, root) => {
    let entries
    try { entries = readdirSync(dir, { withFileTypes: true }) } catch { return }
    for (const e of entries) {
      const full = join(dir, e.name)
      if (e.isDirectory()) { visit(full, root || e.name); continue }
      if (!e.name.endsWith('.jsonl')) continue
      const id = root || e.name.slice(0, -'.jsonl'.length)
      groups.set(id, [...(groups.get(id) || []), full])
    }
  }
  visit(projectDir, null)
  return groups
}

function isDirectory(filePath) {
  try { return statSync(filePath).isDirectory() } catch { return false }
}

const EMPTY = new Set(`esto esta este eso ese aqui alli para porque cuando donde
  como cual cuanto todo toda todos todas otro otra mucho mucha muy mas menos
  pero aunque desde hasta sobre entre segun tambien ahora antes despues siempre
  nunca hacer haces hace tiene tener puede poder debe deja pasa sigue vuelve
  quiero quieres vamos vale bien mal cosa cosas parte partes vez veces
  the this that with from have has been they there their what when where which
  would could should about into your just like make made only over such than
  them then were will your`.split(/\s+/).filter(Boolean))

// Only the message that opens the session: it is the one the person writes, and
// where the work is asked for. Taking more let in pasted code and test output,
// and the suggestions were "classname", "const" and "ntests".
function userWords(text) {
  const words = []
  let messages = 0
  for (const m of text.matchAll(/"type"\s*:\s*"user"[^\n]*?"content"\s*:\s*"((?:[^"\\]|\\.)*)"/g)) {
    if (messages >= 1) break
    const said = m[1]
    if (said.length > 400) continue
    if ((said.match(/\\n/g) || []).length > 2) continue
    messages++
    for (const w of said.toLowerCase().normalize('NFD').replace(/[\u0300-\u036f]/g, '').split(/[^a-z0-9]+/)) {
      if (w.length > 4 && w.length < 20 && !/\d/.test(w) && !EMPTY.has(w)) words.push(w)
    }
  }
  return words
}

function invocations(since) {
  const count = new Map()
  const byScript = new Map()
  const saidThisWay = new Map()
  const scripts = catalogScripts()
  let sessions = 0
  if (!existsSync(TRANSCRIPTS)) return { counts: count, byScript, sessions }

  for (const project of readdirSync(TRANSCRIPTS)) {
    const dir = join(TRANSCRIPTS, project)
    if (!isDirectory(dir)) continue
    for (const parts of sessionsOf(dir).values()) {
      const recent = parts.some((f) => {
        try { return statSync(f).mtimeMs >= since } catch { return false }
      })
      if (!recent) continue
      sessions++
      const text = parts.map((f) => {
        try { return readFileSync(f, 'utf8') } catch { return '' }
      }).join('\n')
      const callsHere = new Set()
      for (const m of text.matchAll(/"name"\s*:\s*"Skill"\s*,\s*"input"\s*:\s*\{\s*"skill"\s*:\s*"([^"]+)"/g)) {
        callsHere.add(m[1])
      }
      for (const skill of callsHere) {
        count.set(skill, (count.get(skill) || 0) + 1)
      }
      if (!scripts.size) continue
      const scriptsHere = new Set()
      for (const m of text.matchAll(/"name"\s*:\s*"Bash"\s*,\s*"input"\s*:\s*\{[^}]*?"command"\s*:\s*"((?:[^"\\]|\\.)*)"/g)) {
        const cmd = m[1]
        if (EDITS_THE_SCRIPT.test(cmd)) continue
        for (const [script, skill] of scripts) {
          for (const h of cmd.matchAll(new RegExp(script.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'g'))) {
            if (READ_VERB.test(cmd.slice(0, h.index))) continue
            scriptsHere.add(skill)
          }
        }
      }
      const saidPhrases = scriptsHere.size ? userWords(text) : []
      for (const skill of scriptsHere) {
        byScript.set(skill, (byScript.get(skill) || 0) + 1)
        if (callsHere.has(skill)) continue
        const counts = saidThisWay.get(skill) || new Map()
        for (const w of saidPhrases) counts.set(w, (counts.get(w) || 0) + 1)
        saidThisWay.set(skill, counts)
      }
    }
  }
  return { counts: count, byScript, sessions, saidThisWay }
}

const since = Date.now() - days * 24 * 3600 * 1000
const cat = catalog()
const { counts: count, byScript, sessions, saidThisWay } = invocations(since)

console.log(`skill usage — last ${days} days · ${sessions} sessions reviewed\n`)

if (!sessions) {
  console.log('No transcripts in the period. No data, not no usage.\n')
  process.exit(0)
}
if (!count.size && !byScript.size) {
  console.log('No invocation found. The transcript format may have')
  console.log('changed: check before concluding that no skill is')
  console.log('used.\n')
  process.exit(0)
}

const names = new Set([...count.keys(), ...byScript.keys()])
const used = [...names]
  .map(n => [n, count.get(n) || 0, byScript.get(n) || 0])
  .sort((a, b) => (b[1] + b[2]) - (a[1] + a[2]))

console.log('Used:\n')
console.log("     call  script  origin           skill")
for (const [name, n, s] of used) {
  const origin = cat.get(name) || '(other source)'
  console.log(`  ${String(n).padStart(7)}  ${String(s || '').padStart(6)}  ${origin.padEnd(16)} ${name}`)
}
// The procedure is followed and the skill is not invoked: it is not that it is
// surplus, it is that its description does not activate when the problem
// shows up. It is the only conclusion the report can draw by itself, and it
// was in plain sight for anyone who knew how to read it.
const silentDescription = used.filter(([n, calls, scripts]) =>
  calls === 0 && scripts > 0 && cat.has(n),
)
if (silentDescription.length) {
  console.log('\nFollowed by hand, and nobody called them by name:\n')
  for (const [name, , scripts] of silentDescription) {
    console.log(`  ${name} — ${scripts} ${scripts === 1 ? 'session' : 'sessions'}`)
    // The words the work was asked for with that its description does not
    // carry: that is what has to go in so it activates by itself.
    const desc = DESCRIPTIONS.get(name) || ''
    const missing = [...(saidThisWay.get(name) || new Map())]
      .filter(([w]) => !desc.includes(w))
      .sort((a, b) => b[1] - a[1])
      .slice(0, 8)
      .map(([w]) => w)
    // With one or two loose words there is no signal, only formatted noise.
    if (missing.length >= 3) console.log(`      asked for like this: ${missing.join(', ')}`)
  }
  console.log('\n  The work got done, so the skill is not surplus: what fails is its')
  console.log('  description, which lacks the words the problem shows up with.')
}

console.log('\n  Both columns count SESSIONS, not executions: a loop that calls the')
console.log('  script eighteen times is still one occasion on which it was used.')
console.log('\n  "call" is the skill invoked by name. "script" is the trace of its')
console.log('  scripts in commands: the procedure followed by hand. They do not add')
console.log('  up: one session may appear in both. Sessions in which the skill itself')
console.log('  was written do not count as use.')

const orphans = used.filter(([n]) => !cat.has(n)).map(([n]) => n)
if (orphans.length) {
  console.log('\nInvoked and absent from this catalog:\n')
  for (const n of orphans) console.log(`  ${n}`)
  console.log('\n  They probably come from the agent itself or a plugin, and then there')
  console.log('  is nothing to fix: crux only knows its two catalogs. If instead it is')
  console.log('  a name of yours that was renamed, fix the reference.')
}

const never = [...cat.entries()].filter(([n]) => !count.has(n) && !byScript.has(n))
if (never.length) {
  console.log(`\nUnused in the period (${never.length} of ${cat.size}):\n`)
  const byOrigin = new Map()
  for (const [n, o] of never) byOrigin.set(o, [...(byOrigin.get(o) || []), n])
  for (const [origin, list] of byOrigin) {
    console.log(`  ${origin}: ${showAll ? list.join(', ') : list.slice(0, 8).join(', ') + (list.length > 8 ? `, +${list.length - 8}` : '')}`)
  }
  console.log('\n  This is not a deletion list. An incident skill that has not been')
  console.log('  used is good news; a newly created one has not had an occasion yet.')
  console.log('  What to look at is the one that has existed for months, covers')
  console.log('  something frequent and still nobody invokes: it is almost always')
  console.log('  that its description does not activate when it should.')
}
console.log()
