#!/usr/bin/env bash
# Traduce el bloque `mcp` del contrato al formato que lee Claude Code.
#
#   mcp.sh write  <crux.json> <destino>   escribe/actualiza <destino>/.mcp.json
#   mcp.sh clear  <crux.json> <destino>   retira solo lo que declara el contrato
#   mcp.sh diff   <crux.json> <destino>   qué hay puesto frente a lo declarado
#
# El contrato es la fuente de verdad y el fichero del cliente es un derivado:
# se reescribe lo declarado, se respeta lo que haya puesto alguien a mano y se
# reporta lo que sobra en vez de borrarlo. Borrar configuración ajena porque no
# aparece en nuestro contrato sería el mismo error que `crux hooks remove`
# evita al retirar únicamente los suyos.
#
# El contrato dice `transport` y el fichero dice `type`. Son la misma idea con
# dos nombres, y traducir entre ellos es exactamente para lo que existe un
# adaptador: el día que otro cliente lo llame de otra forma, el contrato no se
# entera.

set -euo pipefail

CRUX_HOME="${CRUX_HOME:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)}"
export CRUX_HOME
source "$CRUX_HOME/lib/common.sh"

ACCION="${1:?uso: mcp.sh write|clear|diff <crux.json> <destino>}"
CONTRATO="${2:?falta el crux.json}"
DESTINO="${3:?falta el directorio de destino}"

[[ -f "$CONTRATO" ]] || die "no existe $CONTRATO"
[[ -d "$DESTINO" ]] || die "no existe el directorio $DESTINO"

FICHERO="$DESTINO/.mcp.json"

node - "$ACCION" "$CONTRATO" "$FICHERO" <<'JS'
const fs = require('fs')
const [accion, contratoPath, ficheroPath] = process.argv.slice(2)

const contrato = JSON.parse(fs.readFileSync(contratoPath, 'utf8'))
const declarados = contrato.mcp || {}

// Un fichero corrupto no se pisa en silencio: es configuración de alguien.
let actual = { mcpServers: {} }
if (fs.existsSync(ficheroPath)) {
  try {
    actual = JSON.parse(fs.readFileSync(ficheroPath, 'utf8'))
  } catch (e) {
    process.stderr.write(`.mcp.json ilegible (${e.message}) — no se toca\n`)
    process.exit(1)
  }
  actual.mcpServers = actual.mcpServers || {}
}

// La forma que espera el cliente. `repos` es nuestro y no viaja: dice en qué
// repos se escribe este fichero, no cómo se habla con el servidor.
function aFormatoCliente(nombre, d) {
  const transporte = d.transport || 'stdio'
  const salida = { type: transporte }
  if (transporte === 'stdio') {
    if (!d.command) throw new Error(`${nombre}: transport stdio sin 'command'`)
    salida.command = d.command
    if (d.args) salida.args = d.args
    if (d.env) salida.env = d.env
  } else if (transporte === 'http' || transporte === 'sse') {
    if (!d.url) throw new Error(`${nombre}: transport ${transporte} sin 'url'`)
    salida.url = d.url
    if (d.headers) salida.headers = d.headers
  } else {
    throw new Error(`${nombre}: transport '${transporte}' no es stdio, http ni sse`)
  }
  if (d.timeout) salida.timeout = d.timeout
  return salida
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
  // `{"mcpServers":{}}` huérfano en el repo es ruido en el git status de
  // cualquiera que clone.
  if (!Object.keys(actual.mcpServers).length && Object.keys(actual).length === 1) {
    if (fs.existsSync(ficheroPath)) fs.unlinkSync(ficheroPath)
    console.log('borrado')
  } else {
    fs.writeFileSync(ficheroPath, JSON.stringify(actual, null, 2) + '\n')
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
  fs.writeFileSync(ficheroPath, JSON.stringify(actual, null, 2) + '\n')
  console.log(`escritos ${nombres.length}${ajenos.length ? ` (${ajenos.length} ajenos intactos)` : ''}`)
  process.exit(0)
}

process.stderr.write(`acción desconocida: ${accion}\n`)
process.exit(2)
JS
