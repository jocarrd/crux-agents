#!/usr/bin/env node
// Mide la distancia entre lo que se ha movido en el código y lo que se ha
// escrito en la documentación.
//
// No pretende saber QUÉ falta documentar — eso no es medible desde git. Lo que
// sí es medible es si el código lleva avanzando un rato sin que la doc se haya
// movido, y eso basta para levantar la mano.
//
//   check-doc-drift.mjs <docs-repo> [--json]
//
// Sale siempre con 0: quien llama decide si es aviso, error o recordatorio.

import { readFileSync, existsSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import { dirname, join, basename } from 'node:path'

const docs = process.argv[2]
const comoJson = process.argv.includes('--json')

if (!docs) {
  console.error('uso: check-doc-drift.mjs <docs-repo> [--json]')
  process.exit(2)
}

function git(dir, args) {
  try {
    return execFileSync('git', ['-C', dir, ...args], {
      encoding: 'utf-8',
      stdio: ['ignore', 'pipe', 'ignore'],
    }).trim()
  } catch {
    return ''
  }
}

function ultimoCommit(dir) {
  const ts = git(dir, ['log', '-1', '--format=%ct'])
  return ts ? Number(ts) : 0
}

// Estrictamente posteriores: un commit de código en el mismo segundo que el de
// documentación es el caso bueno —se documentó en el mismo turno—, no deriva.
function contarDesde(dir, desde) {
  if (!desde) return 0
  const out = git(dir, ['rev-list', '--count', `--since=@${desde + 1}`, 'HEAD'])
  return out ? Number(out) : 0
}

// En el repo de código lo sin seguir suele ser ruido de build. En el de
// documentación es justo lo contrario: un fichero nuevo sin seguir es una doc
// recién escrita que todavía no está en ningún sitio duradero, que es
// exactamente lo que esto vigila.
function sucios(dir, { incluirNuevos = false } = {}) {
  const out = git(dir, ['status', '--porcelain'])
  if (!out) return 0
  return out.split('\n').filter((l) => {
    if (!l.trim()) return false
    if (!l.startsWith('??')) return true
    return incluirNuevos && l.trim().endsWith('.md')
  }).length
}

const raizProyecto = dirname(docs)
let contrato = {}
try {
  contrato = JSON.parse(readFileSync(join(docs, 'crux.json'), 'utf-8'))
} catch {
  // Sin contrato no hay lista de repos; se sigue con lo que se pueda deducir.
}

const repos = Array.isArray(contrato.repos) ? contrato.repos : []
const docsUltimo = ultimoCommit(docs)
const docsSucios = sucios(docs, { incluirNuevos: true })

const hallazgos = []
let commitsCodigo = 0
let repoMasReciente = 0

for (const repo of repos) {
  const dir = join(raizProyecto, repo)
  if (!existsSync(join(dir, '.git'))) continue

  const ultimo = ultimoCommit(dir)
  if (!ultimo) continue
  if (ultimo > repoMasReciente) repoMasReciente = ultimo

  const n = contarDesde(dir, docsUltimo)
  const pendientes = sucios(dir)
  if (n === 0 && pendientes === 0) continue

  commitsCodigo += n
  hallazgos.push({
    repo,
    commits: n,
    sinCommitear: pendientes,
    ultimo: new Date(ultimo * 1000).toISOString().slice(0, 10),
  })
}

const dias = docsUltimo
  ? Math.floor((Date.now() / 1000 - docsUltimo) / 86400)
  : null

const resumen = {
  docsUltimoCommit: docsUltimo
    ? new Date(docsUltimo * 1000).toISOString().slice(0, 10)
    : null,
  docsDiasSinTocar: dias,
  docsSinCommitear: docsSucios,
  commitsCodigoSinDoc: commitsCodigo,
  repos: hallazgos,
}

if (comoJson) {
  console.log(JSON.stringify(resumen))
  process.exit(0)
}

for (const h of hallazgos) {
  const partes = []
  if (h.commits) {
    partes.push(
      `${h.commits} commit${h.commits === 1 ? '' : 's'} desde el último de docs`,
    )
  }
  if (h.sinCommitear) {
    partes.push(
      `${h.sinCommitear} fichero${h.sinCommitear === 1 ? '' : 's'} sin commitear`,
    )
  }
  console.log(`${h.repo}: ${partes.join(', ')} (último: ${h.ultimo})`)
}

if (docsSucios) {
  console.log(
    `${basename(docs)}: ${docsSucios} fichero${docsSucios === 1 ? '' : 's'} de documentación sin commitear`,
  )
}

process.exit(0)
