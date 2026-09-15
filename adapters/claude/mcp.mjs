#!/usr/bin/env node
// Traduce el bloque `mcp` del contrato al fichero que lee Claude Code.
//
//   mcp.mjs write <crux.json> <destino>   escribe/actualiza <destino>/.mcp.json
//   mcp.mjs clear <crux.json> <destino>   retira solo lo que declara el contrato
//   mcp.mjs diff  <crux.json> <destino>   qué hay puesto frente a lo declarado
//
// El contrato es la fuente de verdad y el fichero del cliente es un derivado: se
// reescribe lo declarado, se respeta lo que haya puesto alguien a mano y se
// reporta lo que sobra en vez de borrarlo. Borrar configuración ajena porque no
// aparece en nuestro contrato sería el mismo error que `crux hooks remove` evita
// al retirar únicamente los suyos.

import { readFileSync, writeFileSync, existsSync, unlinkSync } from 'node:fs'
import { join } from 'node:path'
import { aFormatoCliente } from '../../lib/mcp-format.mjs'

const [accion, contratoPath, destino] = process.argv.slice(2)
if (!accion || !contratoPath || !destino) {
  console.error('uso: mcp.mjs write|clear|diff <crux.json> <destino>')
  process.exit(2)
}

const ficheroPath = join(destino, '.mcp.json')
const declarados = JSON.parse(readFileSync(contratoPath, 'utf8')).mcp || {}

// Un fichero corrupto no se pisa en silencio: es configuración de alguien, y
// quien llama necesita enterarse por el código de salida.
let actual = { mcpServers: {} }
if (existsSync(ficheroPath)) {
  try {
    actual = JSON.parse(readFileSync(ficheroPath, 'utf8'))
  } catch (e) {
    console.error(`.mcp.json ilegible (${e.message}) — no se toca`)
    process.exit(1)
  }
  actual.mcpServers = actual.mcpServers || {}
}

const nombres = Object.keys(declarados)
const ajenos = Object.keys(actual.mcpServers).filter((n) => !nombres.includes(n))

if (accion === 'diff') {
  for (const n of nombres) {
    const esperado = JSON.stringify(aFormatoCliente(n, declarados[n]))
    const puesto = actual.mcpServers[n] ? JSON.stringify(actual.mcpServers[n]) : null
    if (!puesto) console.log(`falta ${n}`)
    else if (puesto !== esperado) console.log(`difiere ${n}`)
    else console.log(`ok ${n}`)
  }
  for (const n of ajenos) console.log(`ajeno ${n}`)
  process.exit(0)
}

if (accion === 'clear') {
  for (const n of nombres) delete actual.mcpServers[n]
  // Un fichero que solo contenía lo nuestro se va entero: dejar un
  // `{"mcpServers":{}}` huérfano es ruido en el git status de quien clone.
  if (!Object.keys(actual.mcpServers).length && Object.keys(actual).length === 1) {
    if (existsSync(ficheroPath)) unlinkSync(ficheroPath)
    console.log('borrado')
  } else {
    writeFileSync(ficheroPath, JSON.stringify(actual, null, 2) + '\n')
    console.log(`retirados ${nombres.length}`)
  }
  process.exit(0)
}

if (accion === 'write') {
  if (!nombres.length) {
    console.log('el contrato no declara ninguno')
    process.exit(0)
  }
  for (const n of nombres) actual.mcpServers[n] = aFormatoCliente(n, declarados[n])
  writeFileSync(ficheroPath, JSON.stringify(actual, null, 2) + '\n')
  console.log(`escritos ${nombres.length}${ajenos.length ? ` (${ajenos.length} ajenos intactos)` : ''}`)
  process.exit(0)
}

console.error(`acción desconocida: ${accion}`)
process.exit(2)
