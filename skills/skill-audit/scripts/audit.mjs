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
import { join, dirname } from 'node:path'
import { homedir } from 'node:os'

// La raíz de proyectos no se asume: sale de la config de la máquina o del sitio
// donde está instalado el kernel, que siempre vive dentro de ella.
function raizProyectos() {
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

const ROOT = process.argv[2] || raizProyectos()

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

// Un valor puede continuar en las líneas siguientes. Sin esto, una descripción
// de dos líneas se cortaba en la primera y este informe medía un texto distinto
// del que mide `probe.mjs`, que es con el que la SKILL.md manda contrastarlo.
function frontmatter(text) {
  const m = text.match(/^---\n([\s\S]*?)\n---/)
  if (!m) return {}
  const out = {}
  let clave = null
  for (const line of m[1].split('\n')) {
    const kv = line.match(/^([\w-]+):\s*(.*)$/)
    if (kv) {
      clave = kv[1]
      out[clave] = kv[2]
    } else if (clave && line.trim()) {
      out[clave] = `${out[clave]} ${line.trim()}`.trim()
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
  console.log(`sin proyectos adoptados bajo ${ROOT}`)
  process.exit(0)
}

// Un adaptador de una skill del kernel también tiene baja densidad, porque su
// contenido técnico ya está depurado de nombres propios. Sin esto, el informe
// propone una y otra vez promover lo que ya está promovido.
const kernelDir = join(process.env.CRUX_HOME || join(ROOT, 'crux'), 'skills')
const kernelSkills = existsSync(kernelDir)
  ? readdirSync(kernelDir).filter(n => statSync(join(kernelDir, n)).isDirectory())
  : []

// La descripción del procedimiento, no solo su nombre: sin ella no se puede
// medir si el adaptador que quedó abajo compite con lo que se promovió.
const kernelDesc = new Map(
  kernelSkills.map(n => {
    const f = join(kernelDir, n, 'SKILL.md')
    return [n, existsSync(f) ? (frontmatter(readFileSync(f, 'utf8')).description || '') : '']
  }),
)

const all = []

for (const p of projects) {
  const cfg = JSON.parse(readFileSync(p.cfg, 'utf8'))
  // Los nombres propios de un proyecto son su nombre y los de sus repos: eso
  // ya está declarado en el contrato, no hace falta mantenerlo aparte.
  const enteros = [cfg.project, ...(cfg.repos || [])].map(t => String(t).toLowerCase())
  const fragmentos = enteros
    .flatMap(t => t.split(/[-_]/))
    .filter(t => t.length > 2)
  const terms = [...enteros, ...fragmentos]
  const re = new RegExp(`\\b(${[...new Set(terms)].join('|')})\\b`, 'gi')

  for (const file of walkSkills(join(p.path, '.claude', 'skills'))) {
    const text = readFileSync(file, 'utf8')
    const fm = frontmatter(text)
    const lines = text.split('\n').length
    const hits = (text.match(re) || []).length
    const adapts = kernelSkills.filter(k => new RegExp(`(?<![\\w-])${k}(?![\\w-]|\\.\\w)`).test(text))
    // La densidad mira el fichero entero, pero al agente solo se le enseña la
    // descripción: un adaptador con veinte nombres propios en el cuerpo y
    // ninguno arriba es indistinguible del procedimiento que adapta.
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

const UMBRAL_PARECIDO = 0.18

const pairs = []
for (let i = 0; i < all.length; i++) {
  for (let j = i + 1; j < all.length; j++) {
    if (all[i].project === all[j].project) continue
    const sim = jaccard(tokens(all[i].description), tokens(all[j].description))
    if (sim >= UMBRAL_PARECIDO) pairs.push({ a: all[i], b: all[j], sim: +sim.toFixed(2) })
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

// La secuela de una promoción. Hasta aquí el informe miraba hacia delante —qué
// merece subir—, y el par que la propia promoción deja atrás no lo veía nadie:
// el procedimiento arriba y su adaptador abajo, compitiendo por el mismo
// enunciado. Se descubrió midiendo el ejemplo canónico del estándar,
// device-loop y su adaptador, que daban un empate exacto.
//
// Dos señales, porque una sola no basta: se pisan mucho, o no se distinguen en
// lo único que el agente compara.
//
// `adapts` se deduce de mencionar el nombre de una skill del kernel en el
// texto, y nombres como `flow` o `workspace` son también palabras corrientes.
// Por eso el solape se reporta por par —donde el falso positivo se ve y da
// 0—, y la falta de nombres propios una sola vez por adaptador: es una
// propiedad suya, no de la pareja.
const colisiones = []
for (const a of adapters) {
  for (const k of a.adapts) {
    const sim = jaccard(tokens(a.description), tokens(kernelDesc.get(k) || ''))
    if (sim >= UMBRAL_PARECIDO) colisiones.push({ a, k, sim: +sim.toFixed(2) })
  }
}
const mudos = adapters.filter(a => !a.hitsDesc)

if (colisiones.length) {
  console.log('\nAdaptadores parecidos a su procedimiento — comprueba cómo reparten:\n')
  for (const c of colisiones.sort((x, y) => y.sim - x.sim)) {
    console.log(`  ${c.sim}  ${c.a.project}/${c.a.name}  vs  kernel/${c.k}`)
  }
  // Parecerse no es competir, y medido sobre los adaptadores reales este número
  // señaló seis cuando el que fallaba era uno. Dos skills que hablan de
  // desplegar sin CI comparten vocabulario por fuerza; lo que decide es quién
  // gana cada frase, y eso necesita las dos frases, que este informe no tiene.
  console.log('\n  Compartir vocabulario es inevitable: el adaptador habla del mismo')
  console.log('  trabajo. Lo que no puede pasar es que gane una frase sin nombres')
  console.log('  propios, porque entonces gana también en los proyectos donde no')
  console.log('  aplica. El veredicto lo da la prueba de las dos frases:\n')
  for (const c of colisiones.sort((x, y) => y.sim - x.sim)) {
    console.log(`    probe.mjs --adaptador ${c.a.name} ${c.k} "<frase genérica>" "<frase con nombres propios>"`)
  }
  console.log()
} else if (adapters.length) {
  console.log('\nNingún adaptador se parece a su procedimiento.\n')
}

if (mudos.length) {
  console.log('Adaptadores que no nombran su proyecto en la descripción:\n')
  for (const a of mudos) console.log(`  ${a.project}/${a.name}`)
  console.log('\n  La densidad de arriba mira el fichero entero, pero al agente solo se')
  console.log('  le enseña la descripción. Un adaptador que no se nombra ahí no se')
  console.log('  distingue del procedimiento, y puja en los demás proyectos.\n')
}

if (adapters.length) {
  console.log('Ya son adaptadores de una skill del kernel:\n')
  for (const s of adapters) {
    console.log(`  ${s.project}/${s.name}  ->  ${s.adapts.join(', ')}`)
  }
}
