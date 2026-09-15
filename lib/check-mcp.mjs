#!/usr/bin/env node
// Revisa el bloque `mcp` del contrato: que cada servidor esté bien declarado,
// que no lleve credenciales escritas dentro y que lo que hay en los .mcp.json
// siga siendo lo que el contrato dice.
//
// No abre ninguna conexión. Comprobar que un servidor responde es preguntarle a
// la red, y `crux doctor` tiene que tardar lo mismo y decir lo mismo con wifi y
// sin ella. Eso lo contesta `crux mcp status`, que se ejecuta cuando importa.
//
// Cada hallazgo sale con su severidad delante: `error` si el fichero resultante
// sería inválido o si hay un secreto escrito, `aviso` si solo se ha ido de lo
// declarado.

import { readFileSync, existsSync } from 'node:fs'
import { join, dirname, basename } from 'node:path'
import { huellasEn } from './credential-prints.mjs'
import { aFormatoCliente, textosDe, reposDe, TRANSPORTES } from './mcp-format.mjs'

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

// La misma regla que el resto del kernel aplica a los nombres: no se legisla el
// estilo, se cierra lo que hace daño. Un nombre se concatena a rutas y a
// expresiones, y el primero que llevaba una comilla doble ejecutaba código al
// leer el contrato de un proyecto clonado.
const NOMBRE = /^[A-Za-z0-9][A-Za-z0-9._-]*$/

// Un valor sin referencia a variable de entorno es un literal, y un literal en
// una cabecera de autorización viaja a git.
const SENSIBLE = /(authorization|api[-_]?key|token|secret|password|bearer)/i

for (const [nombre, d] of Object.entries(declarados)) {
  if (!NOMBRE.test(nombre) || nombre.includes('..')) {
    hallazgos.push(
      `error '${nombre}' no vale como nombre de servidor — letras, dígitos, punto, guion y guion bajo`,
    )
    continue
  }

  const transporte = d.transport || 'stdio'
  if (!TRANSPORTES.includes(transporte)) {
    hallazgos.push(`error ${nombre}: transport '${transporte}' — solo ${TRANSPORTES.join(', ')}`)
    continue
  }

  // La forma la decide quien la escribe, para que doctor y adaptador no puedan
  // discrepar sobre qué es válido.
  try {
    aFormatoCliente(nombre, d)
  } catch (e) {
    hallazgos.push(`error ${e.message}`)
  }

  if (transporte === 'stdio' && d.url) {
    hallazgos.push(`aviso ${nombre}: 'url' no se usa con transport stdio`)
  }
  if (transporte !== 'stdio' && (d.command || d.args)) {
    hallazgos.push(`aviso ${nombre}: 'command'/'args' no se usan con transport ${transporte}`)
  }

  for (const { donde, texto, clave } of textosDe(d)) {
    for (const huella of huellasEn(texto)) {
      hallazgos.push(`error ${nombre}: ${huella} escrito en ${donde}`)
    }
    if (clave && SENSIBLE.test(clave) && !texto.includes('${')) {
      hallazgos.push(
        `error ${nombre}: ${donde} lleva un valor literal — usa \${VARIABLE}, el fichero se commitea`,
      )
    }
  }
}

// Deriva en los dos sentidos. Mirar solo lo que sobra en el fichero dejaba pasar
// lo que falta —una máquina recién clonada no tiene ninguno— y, peor, un valor
// cambiado a mano: el doctor firmaba como conforme un .mcp.json cuya url
// apuntaba a otro sitio.
const raiz = dirname(docs)

// Dónde debería haber fichero, según lo que pide cada servidor. Un repo que no
// está clonado no cuenta: de eso ya avisa el bloque 3 del doctor.
const esperados = new Set([docs])
for (const n of Object.keys(declarados)) {
  for (const r of reposDe(contrato, n)) {
    if (existsSync(join(raiz, r))) esperados.add(join(raiz, r))
  }
}

for (const dir of [docs, ...(contrato.repos || []).map((r) => join(raiz, r))]) {
  const fichero = join(dir, '.mcp.json')
  const etiqueta = basename(dir)
  if (!existsSync(fichero)) {
    if (esperados.has(dir)) {
      hallazgos.push(`aviso ${etiqueta} no tiene .mcp.json — ejecuta 'crux mcp install'`)
    }
    continue
  }

  let puesto
  try {
    puesto = JSON.parse(readFileSync(fichero, 'utf8'))
  } catch (e) {
    hallazgos.push(`error ${etiqueta}/.mcp.json ilegible: ${e.message}`)
    continue
  }
  const servidores = puesto.mcpServers || {}

  for (const n of Object.keys(servidores)) {
    if (!declarados[n]) {
      hallazgos.push(`aviso ${etiqueta}/.mcp.json tiene '${n}', que el contrato no declara`)
    }
  }
  for (const [n, d] of Object.entries(declarados)) {
    if (!servidores[n]) continue
    let esperado
    try {
      esperado = aFormatoCliente(n, d)
    } catch {
      continue // ya se ha reportado arriba como error de forma
    }
    if (JSON.stringify(servidores[n]) !== JSON.stringify(esperado)) {
      hallazgos.push(
        `aviso ${etiqueta}/.mcp.json tiene '${n}' distinto de lo declarado — 'crux mcp install'`,
      )
    }
  }
}

for (const h of hallazgos) console.log(h)
process.exit(0)
