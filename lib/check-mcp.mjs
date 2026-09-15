#!/usr/bin/env node
// Revisa el bloque `mcp` del contrato: que cada servidor esté bien declarado,
// que no lleve credenciales escritas dentro y que lo que hay en los .mcp.json
// siga siendo lo que el contrato dice.
//
// No abre ninguna conexión. Comprobar que un servidor responde es preguntarle
// a la red, y `crux doctor` tiene que dar el mismo resultado con o sin wifi y
// tardar lo mismo. Esa comprobación vive en `crux mcp status`, que se ejecuta
// cuando uno quiere saberlo.
//
// Cada hallazgo sale con su severidad delante: `error` si el .mcp.json
// resultante sería inválido o si hay un secreto escrito, `aviso` si solo se ha
// ido de lo declarado.

import { readFileSync, existsSync } from 'node:fs'
import { join, dirname, basename } from 'node:path'

const docs = process.argv[2]
if (!docs) {
  console.error('uso: check-mcp.mjs <docs-repo>')
  process.exit(2)
}

const contratoPath = join(docs, 'crux.json')
if (!existsSync(contratoPath)) process.exit(0)

let contrato
try {
  contrato = JSON.parse(readFileSync(contratoPath, 'utf8'))
} catch {
  process.exit(0) // el contrato ilegible ya lo reporta el bloque 1 de doctor
}

const declarados = contrato.mcp
if (!declarados || !Object.keys(declarados).length) process.exit(0)

const hallazgos = []
const TRANSPORTES = ['stdio', 'http', 'sse']

// Las mismas huellas que `check-secrets.mjs`: formatos que no admiten
// discusión. Aquí importan más, porque un .mcp.json se commitea sin que nadie
// lo lea y el hook de secretos solo mira ficheros .md.
const HUELLAS = [
  { nombre: 'token de GitHub', rx: /\bgh[pousr]_[A-Za-z0-9]{20,}/ },
  { nombre: 'clave secreta en vivo', rx: /\bsk_live_[A-Za-z0-9]{10,}/ },
  { nombre: 'clave de API de OpenAI', rx: /\bsk-[A-Za-z0-9]{32,}/ },
  { nombre: 'clave de acceso de AWS', rx: /\bAKIA[0-9A-Z]{16}\b/ },
  { nombre: 'JSON Web Token', rx: /\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\./ },
]

// Un valor que no es una referencia a variable de entorno es un literal, y un
// literal en una cabecera de autorización viaja a git.
const REFERENCIA = /^\$\{[A-Za-z_][A-Za-z0-9_]*\}$/
const SENSIBLE = /(authorization|api[-_]?key|token|secret|password|bearer)/i

for (const [nombre, d] of Object.entries(declarados)) {
  const transporte = d.transport || 'stdio'

  if (!TRANSPORTES.includes(transporte)) {
    hallazgos.push(`error ${nombre}: transport '${transporte}' — solo ${TRANSPORTES.join(', ')}`)
    continue
  }
  if (transporte === 'stdio' && !d.command) {
    hallazgos.push(`error ${nombre}: transport stdio sin 'command'`)
  }
  if ((transporte === 'http' || transporte === 'sse') && !d.url) {
    hallazgos.push(`error ${nombre}: transport ${transporte} sin 'url'`)
  }
  if (transporte === 'stdio' && d.url) {
    hallazgos.push(`aviso ${nombre}: 'url' no se usa con transport stdio`)
  }
  if (transporte !== 'stdio' && (d.command || d.args)) {
    hallazgos.push(`aviso ${nombre}: 'command'/'args' no se usan con transport ${transporte}`)
  }

  for (const campo of ['headers', 'env']) {
    for (const [clave, valor] of Object.entries(d[campo] || {})) {
      const texto = String(valor)
      for (const { nombre: huella, rx } of HUELLAS) {
        if (rx.test(texto)) {
          hallazgos.push(`error ${nombre}: ${huella} escrito en ${campo}.${clave}`)
        }
      }
      if (SENSIBLE.test(clave) && !REFERENCIA.test(texto.trim()) && !/\$\{/.test(texto)) {
        hallazgos.push(
          `error ${nombre}: ${campo}.${clave} lleva un valor literal — usa \${VARIABLE}, el fichero se commitea`,
        )
      }
    }
  }
}

// Deriva: lo declarado frente a lo que hay escrito en cada repo.
const raiz = dirname(docs)
const candidatos = [docs, ...(contrato.repos || []).map((r) => join(raiz, r))]

for (const dir of candidatos) {
  const fichero = join(dir, '.mcp.json')
  if (!existsSync(fichero)) continue
  let puesto
  try {
    puesto = JSON.parse(readFileSync(fichero, 'utf8'))
  } catch (e) {
    hallazgos.push(`error ${basename(dir)}/.mcp.json ilegible: ${e.message}`)
    continue
  }
  const servidores = Object.keys(puesto.mcpServers || {})
  for (const n of servidores) {
    if (!declarados[n]) {
      hallazgos.push(
        `aviso ${basename(dir)}/.mcp.json tiene '${n}', que el contrato no declara`,
      )
    }
  }
}

for (const h of hallazgos) console.log(h)
process.exit(0)
