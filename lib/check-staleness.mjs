#!/usr/bin/env node
import { readFileSync, globSync } from 'node:fs'
import { join } from 'node:path'

const docs = process.argv[2]
const meses = Number(process.argv[3] || 6)
if (!docs) {
  console.error('uso: check-staleness.mjs <docs-repo> [meses]')
  process.exit(2)
}

// Solo lo que se ejecuta. En architecture/ o conventions/ lo obsoleto se nota
// al leer; en operations/ se nota cuando el comando falla con el sistema caído.
let ficheros = []
try {
  ficheros = globSync('operations/**/*.md', { cwd: docs })
} catch {
  ficheros = []
}

const limite = Date.now() - meses * 30 * 24 * 3600 * 1000
const MARCA = /^>\s*Última verificación:\s*(\d{4}-\d{2}-\d{2})\s*$/m

for (const rel of ficheros.sort()) {
  const texto = readFileSync(join(docs, rel), 'utf-8')
  const m = texto.match(MARCA)
  if (!m) continue
  const fecha = Date.parse(m[1])
  if (Number.isNaN(fecha)) {
    console.log(`${rel} tiene una fecha de verificación que no se entiende: ${m[1]}`)
    continue
  }
  if (fecha < limite) {
    const dias = Math.round((Date.now() - fecha) / (24 * 3600 * 1000))
    console.log(`${rel} sin verificar desde hace ${dias} días`)
  }
}
process.exit(0)
