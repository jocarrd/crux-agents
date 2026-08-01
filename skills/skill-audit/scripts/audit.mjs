#!/usr/bin/env node
// Inventaría las skills de todos los proyectos y señala cuáles podrían ser
// patrones disfrazados de adaptadores.
//
//   audit.mjs [dir-de-proyectos]
//
// Dos señales:
//   1. Densidad de nombres propios. Los términos se derivan del crux.json de
//      cada proyecto, no de una lista escrita a mano.
//   2. Pares de skills de proyectos distintos que describen lo mismo. Es la
//      promoción más obvia y la más invisible: nadie ve las dos a la vez.

import { readFileSync, readdirSync, existsSync, statSync } from 'node:fs'
import { join } from 'node:path'
import { homedir } from 'node:os'

const ROOT = process.argv[2] || join(homedir(), 'Proyectos')

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

function frontmatter(text) {
  const m = text.match(/^---\n([\s\S]*?)\n---/)
  if (!m) return {}
  const out = {}
  for (const line of m[1].split('\n')) {
    const kv = line.match(/^(\w+):\s*(.*)$/)
    if (kv) out[kv[1]] = kv[2]
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
  console.log(`sin proyectos adoptados bajo ${ROOT}`)
  process.exit(0)
}

// Un adaptador de una skill del kernel también tiene baja densidad, porque su
// contenido técnico ya está depurado de nombres propios. Sin esto, el informe
// propone una y otra vez promover lo que ya está promovido.
const kernelSkills = (() => {
  const dir = join(process.env.CRUX_HOME || join(homedir(), 'Proyectos', 'crux'), 'skills')
  return existsSync(dir) ? readdirSync(dir).filter(n => statSync(join(dir, n)).isDirectory()) : []
})()

const all = []

for (const p of projects) {
  const cfg = JSON.parse(readFileSync(p.cfg, 'utf8'))
  // Los nombres propios de un proyecto son su nombre y los de sus repos: eso
  // ya está declarado en el contrato, no hace falta mantenerlo aparte.
  const terms = [cfg.project, ...(cfg.repos || [])]
    .flatMap(t => [t, ...String(t).split(/[-_]/)])
    .map(t => String(t).toLowerCase())
    .filter(t => t.length > 3)
  const re = new RegExp(`\\b(${[...new Set(terms)].join('|')})\\b`, 'gi')

  for (const file of walkSkills(join(p.path, '.claude', 'skills'))) {
    const text = readFileSync(file, 'utf8')
    const fm = frontmatter(text)
    const lines = text.split('\n').length
    const hits = (text.match(re) || []).length
    const adapts = kernelSkills.filter(k => new RegExp(`\\b${k}\\b`).test(text))
    all.push({
      project: cfg.project,
      name: fm.name || file.split('/').slice(-2)[0],
      description: fm.description || '',
      file, lines, hits, adapts,
      density: +(hits / lines).toFixed(3),
    })
  }
}

console.log(`skills inventariadas: ${all.length} en ${projects.length} proyectos\n`)

const adapters = all.filter(s => s.adapts.length)
const candidates = all
  .filter(s => s.density < 0.05 && !s.adapts.length)
  .sort((a, b) => a.density - b.density)
if (candidates.length) {
  console.log('Baja densidad de nombres propios — posibles patrones:\n')
  console.log('  dens.  hits/líneas  proyecto      skill')
  for (const s of candidates) {
    console.log(`  ${String(s.density).padEnd(6)} ${String(s.hits + '/' + s.lines).padEnd(12)} ${s.project.padEnd(13)} ${s.name}`)
  }
  console.log('\n  Aplica el test: tapa los nombres propios. Si el procedimiento sigue')
  console.log('  teniendo sentido y valor, hay un patrón dentro.\n')
} else {
  console.log('Ninguna skill con densidad sospechosamente baja.\n')
}

const pairs = []
for (let i = 0; i < all.length; i++) {
  for (let j = i + 1; j < all.length; j++) {
    if (all[i].project === all[j].project) continue
    const sim = jaccard(tokens(all[i].description), tokens(all[j].description))
    if (sim >= 0.18) pairs.push({ a: all[i], b: all[j], sim: +sim.toFixed(2) })
  }
}

if (pairs.length) {
  console.log('Skills de proyectos distintos que describen lo mismo:\n')
  for (const p of pairs.sort((x, y) => y.sim - x.sim)) {
    console.log(`  ${p.sim}  ${p.a.project}/${p.a.name}  vs  ${p.b.project}/${p.b.name}`)
  }
  console.log('\n  Dos proyectos resolviendo el mismo problema por separado es la')
  console.log('  promoción más clara que existe: cumple la regla de las dos ocurrencias.\n')
} else {
  console.log('Sin duplicados semánticos entre proyectos.\n')
}

if (adapters.length) {
  console.log('Ya son adaptadores de una skill del kernel:\n')
  for (const s of adapters) {
    console.log(`  ${s.project}/${s.name}  ->  ${s.adapts.join(', ')}`)
  }
}
