#!/usr/bin/env node
import { readFileSync } from 'node:fs'
import { globSync } from 'node:fs'
import { join, relative } from 'node:path'
import { HUELLAS } from './credential-prints.mjs'

const docs = process.argv[2]
if (!docs) {
  console.error('uso: check-secrets.mjs <docs-repo>')
  process.exit(2)
}


// Una contraseña suelta dentro de un bloque de código no tiene formato que
// reconocer, así que se mira su forma: larga, sin espacios y mezclando clases
// de carácter. Los hashes y los identificadores quedan fuera porque son de una
// sola clase, y las de ejemplo porque se nombran a sí mismas.
const EJEMPLO = /(changeme|example|ejemplo|demo|dev|test|password|contrasena|contraseña|secret|xxxx|placeholder|your|tu-)/i
const HEX = /^[0-9a-f]+$/i

function pareceContrasena(linea) {
  const s = linea.trim()
  if (s.length < 12 || s.length > 64 || /\s/.test(s)) return false
  if (EJEMPLO.test(s) || HEX.test(s)) return false
  // Sintaxis, no credenciales: JSON, ficheros de configuración, rutas, código.
  if (/["'`:=,{}()[\]<>;|\/.@\\]/.test(s)) return false
  const clases =
    (/[a-z]/.test(s) ? 1 : 0) +
    (/[A-Z]/.test(s) ? 1 : 0) +
    (/[0-9]/.test(s) ? 1 : 0)
  return clases >= 3
}

const hallazgos = []
let ficheros = []
try {
  // Además de la documentación, los .mcp.json: se generan desde el contrato,
  // se commitean y no los lee nadie, que es la combinación con la que un token
  // acaba en el historial sin que nadie se entere.
  ficheros = globSync(['**/*.md', '**/.mcp.json'], { cwd: docs }).filter(
    (f) => !f.startsWith('.git/'),
  )
} catch {
  ficheros = []
}

for (const rel of ficheros.sort()) {
  const lineas = readFileSync(join(docs, rel), 'utf-8').split('\n')
  let enBloque = false
  lineas.forEach((linea, i) => {
    if (linea.trimStart().startsWith('```')) {
      enBloque = !enBloque
      return
    }
    for (const { nombre, rx } of HUELLAS) {
      if (rx.test(linea)) hallazgos.push(`${rel}:${i + 1} ${nombre}`)
    }
    if (enBloque && pareceContrasena(linea)) {
      hallazgos.push(`${rel}:${i + 1} posible contraseña suelta`)
    }
  })
}

for (const h of hallazgos) console.log(h)
process.exit(0)
