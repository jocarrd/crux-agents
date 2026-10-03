#!/usr/bin/env node
// Inventories the skills of every project and flags which ones could be
// patterns disguised as adapters.
//
//   audit.mjs [projects-dir]
//
// Two signals:
//   1. Density of proper names. The terms are derived from each project's
//      crux.json, not from a hand-written list.
//   2. Pairs of skills from different projects that describe the same thing.
//      It is the most obvious promotion and the most invisible: nobody sees
//      both at once.

import { readFileSync, readdirSync, existsSync, statSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { homedir } from 'node:os'

// The projects root is not assumed: it comes from the machine config or from
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

const ROOT = process.argv[2] || projectsRoot()

const STOP = new Set(`de la el en y a los las del un una para con por que se su al lo como más o
usa cuando the of and to in for when a is it this that use uses using skill
proyecto project repo repos código codigo local docs documentación`.split(/\s+/))

function findProjects(root) {
  const out = []
  for (const entry of readdirSync(root, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue
    const dir = join(root, entry.name)
    for (const sub of readdirSync(dir, { withFileTypes: true })) {
      if (!sub.isDirectory() || !sub.name.endsWith('-docs')) continue
      const cfg = join(dir, sub.name, 'crux.json')
      if (existsSync(cfg)) out.push({ path: join(dir, sub.name), cfg })
    }
  }
  return out
}

function walkSkills(dir) {
  const out = []
  if (!existsSync(dir)) return out
  const stack = [dir]
  while (stack.length) {
    const cur = stack.pop()
    for (const e of readdirSync(cur, { withFileTypes: true })) {
      const full = join(cur, e.name)
      if (e.isDirectory()) stack.push(full)
      else if (e.name === 'SKILL.md') out.push(full)
    }
  }
  return out
}

// A value can continue on the following lines. Without this, a two-line
// description was cut at the first and this report measured a different text
// from the one `probe.mjs` measures, which is what SKILL.md says to check it
// against.
function frontmatter(text) {
  const m = text.match(/^---\n([\s\S]*?)\n---/)
  if (!m) return {}
  const out = {}
  let key = null
  for (const line of m[1].split('\n')) {
    const kv = line.match(/^([\w-]+):\s*(.*)$/)
    if (kv) {
      key = kv[1]
      out[key] = kv[2]
    } else if (key && line.trim()) {
      out[key] = `${out[key]} ${line.trim()}`.trim()
    }
  }
  return out
}

function tokens(s) {
  return new Set(
    s.toLowerCase().replace(/[^\p{L}\p{N}\s-]/gu, ' ').split(/\s+/)
      .filter(w => w.length > 3 && !STOP.has(w))
  )
}

function jaccard(a, b) {
  const inter = [...a].filter(x => b.has(x)).length
  const union = new Set([...a, ...b]).size
  return union ? inter / union : 0
}

const projects = findProjects(ROOT)
if (!projects.length) {
  console.log(`no adopted projects under ${ROOT}`)
  process.exit(0)
}

// An adapter of a kernel skill also has low density, because its technical
// content is already stripped of proper names. Without this, the report keeps
// proposing to promote what is already promoted.
const kernelDir = join(process.env.CRUX_HOME || join(ROOT, 'crux'), 'skills')
const kernelSkills = existsSync(kernelDir)
  ? readdirSync(kernelDir).filter(n => statSync(join(kernelDir, n)).isDirectory())
  : []

// The procedure's description, not just its name: without it there is no way
// to measure whether the adapter left below competes with what was promoted.
const kernelDesc = new Map(
  kernelSkills.map(n => {
    const f = join(kernelDir, n, 'SKILL.md')
    return [n, existsSync(f) ? (frontmatter(readFileSync(f, 'utf8')).description || '') : '']
  }),
)

const all = []

for (const p of projects) {
  const cfg = JSON.parse(readFileSync(p.cfg, 'utf8'))
  // A project's proper names are its name and its repos' names: that is
  // already declared in the contract, no need to maintain it separately.
  const whole = [cfg.project, ...(cfg.repos || [])].map(t => String(t).toLowerCase())
  const fragments = whole
    .flatMap(t => t.split(/[-_]/))
    .filter(t => t.length > 2)
  const terms = [...whole, ...fragments]
  const re = new RegExp(`\\b(${[...new Set(terms)].join('|')})\\b`, 'gi')

  for (const file of walkSkills(join(p.path, '.claude', 'skills'))) {
    const text = readFileSync(file, 'utf8')
    const fm = frontmatter(text)
    const lines = text.split('\n').length
    const hits = (text.match(re) || []).length
    const adapts = kernelSkills.filter(k => new RegExp(`(?<![\\w-])${k}(?![\\w-]|\\.\\w)`).test(text))
    // Density looks at the whole file, but the agent is only shown the
    // description: an adapter with twenty proper names in the body and none
    // above is indistinguishable from the procedure it adapts.
    const hitsDesc = ((fm.description || '').match(re) || []).length
    all.push({
      project: cfg.project,
      name: fm.name || file.split('/').slice(-2)[0],
      description: fm.description || '',
      file, lines, hits, adapts, hitsDesc,
      density: +(hits / lines).toFixed(3),
    })
  }
}

console.log(`skills inventoried: ${all.length} in ${projects.length} projects\n`)

const adapters = all.filter(s => s.adapts.length)
const candidates = all
  .filter(s => s.density < 0.05 && !s.adapts.length)
  .sort((a, b) => a.density - b.density)
if (candidates.length) {
  console.log('Low density of proper names — possible patterns:\n')
  console.log('  dens.  hits/lines   project       skill')
  for (const s of candidates) {
    console.log(`  ${String(s.density).padEnd(6)} ${String(s.hits + '/' + s.lines).padEnd(12)} ${s.project.padEnd(13)} ${s.name}`)
  }
  console.log('\n  Apply the test: cover the proper names. If the procedure still')
  console.log('  makes sense and has value, there is a pattern inside.\n')
} else {
  console.log('No skill with suspiciously low density.\n')
}

const SIMILARITY_THRESHOLD = 0.18

const pairs = []
for (let i = 0; i < all.length; i++) {
  for (let j = i + 1; j < all.length; j++) {
    if (all[i].project === all[j].project) continue
    const similarity = jaccard(tokens(all[i].description), tokens(all[j].description))
    if (similarity >= SIMILARITY_THRESHOLD) pairs.push({ a: all[i], b: all[j], sim: +similarity.toFixed(2) })
  }
}

if (pairs.length) {
  console.log('Skills from different projects that describe the same thing:\n')
  for (const p of pairs.sort((x, y) => y.sim - x.sim)) {
    console.log(`  ${p.sim}  ${p.a.project}/${p.a.name}  vs  ${p.b.project}/${p.b.name}`)
  }
  console.log('\n  Two projects solving the same problem separately is the clearest')
  console.log('  promotion there is: it meets the two-occurrences rule.\n')
} else {
  console.log('No semantic duplicates between projects.\n')
}

// The aftermath of a promotion. Until here the report looked forward (what
// deserves promoting), and nobody saw the pair the promotion itself leaves
// behind: the procedure above and its adapter below, competing for the same
// statement. It was discovered by measuring the standard's canonical example,
// device-loop and its adapter, which gave an exact tie.
//
// Two signals, because one is not enough: they overlap a lot, or they cannot
// be told apart on the only thing the agent compares.
//
// `adapts` is deduced from mentioning a kernel skill's name in the text, and
// names like `flow` or `workspace` are also ordinary words. That is why the
// overlap is reported per pair (where the false positive is visible and gives
// 0), and the lack of proper names once per adapter: it is a property of the
// adapter, not of the pair.
const collisions = []
for (const a of adapters) {
  for (const k of a.adapts) {
    const similarity = jaccard(tokens(a.description), tokens(kernelDesc.get(k) || ''))
    if (similarity >= SIMILARITY_THRESHOLD) collisions.push({ a, k, sim: +similarity.toFixed(2) })
  }
}
const silent = adapters.filter(a => !a.hitsDesc)

if (collisions.length) {
  console.log('\nAdapters similar to their procedure — check how they split:\n')
  for (const c of collisions.sort((x, y) => y.sim - x.sim)) {
    console.log(`  ${c.sim}  ${c.a.project}/${c.a.name}  vs  kernel/${c.k}`)
  }
  // Resembling is not competing, and measured on the real adapters this number
  // flagged six when only one failed. Two skills that talk about deploying
  // without CI share vocabulary by necessity; what decides is who wins each
  // sentence, and that needs the two sentences, which this report lacks.
  console.log('\n  Sharing vocabulary is inevitable: the adapter talks about the same')
  console.log('  work. What cannot happen is that it wins a sentence without proper')
  console.log('  names, because then it also wins in the projects where it does not')
  console.log('  apply. The verdict comes from the two-sentence test:\n')
  for (const c of collisions.sort((x, y) => y.sim - x.sim)) {
    console.log(`    probe.mjs --adaptador ${c.a.name} ${c.k} "<generic sentence>" "<sentence with proper names>"`)
  }
  console.log()
} else if (adapters.length) {
  console.log('\nNo adapter resembles its procedure.\n')
}

if (silent.length) {
  console.log('Adapters that do not name their project in the description:\n')
  for (const a of silent) console.log(`  ${a.project}/${a.name}`)
  console.log('\n  The density above looks at the whole file, but the agent is only')
  console.log('  shown the description. An adapter that does not name itself there')
  console.log('  is indistinguishable from the procedure, and bids in other projects.\n')
}

if (adapters.length) {
  console.log('Already adapters of a kernel skill:\n')
  for (const s of adapters) {
    console.log(`  ${s.project}/${s.name}  ->  ${s.adapts.join(', ')}`)
  }
}
