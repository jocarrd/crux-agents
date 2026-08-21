#!/usr/bin/env node
import { readFileSync } from 'node:fs'
import { globSync } from 'node:fs'
import { join, relative } from 'node:path'

const docs = process.argv[2]
if (!docs) {
  console.error('uso: check-secrets.mjs <docs-repo>')
  process.exit(2)
}

// Formatos de credencial que no admiten discusión: si aparece uno, alguien
// pegó algo real. Se buscan estos y no "parece una contraseña" porque la
// documentación está llena de ejemplos, y un aviso que grita por cada
// `changeme-dev` enseña a ignorar los avisos.
const HUELLAS = [
  { nombre: 'clave publicable de Stripe/Clerk en vivo', rx: /\bpk_live_[A-Za-z0-9]{10,}/ },
  { nombre: 'clave secreta en vivo', rx: /\bsk_live_[A-Za-z0-9]{10,}/ },
  { nombre: 'token de GitHub', rx: /\bgh[pousr]_[A-Za-z0-9]{20,}/ },
  { nombre: 'clave de acceso de AWS', rx: /\bAKIA[0-9A-Z]{16}\b/ },
  { nombre: 'JSON Web Token', rx: /\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\./ },
  { nombre: 'clave de API de OpenAI', rx: /\bsk-[A-Za-z0-9]{32,}/ },
  { nombre: 'URL con contraseña dentro', rx: /\b[a-z][a-z0-9+.-]*:\/\/[^\s/:@]+:[^\s/@]{6,}@(?!localhost|127\.0\.0\.1|::1|host\.docker)/ },
  { nombre: 'clave privada', rx: /-----BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY-----/ },
]

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
  ficheros = globSync('**/*.md', { cwd: docs }).filter((f) => !f.startsWith('.git/'))
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
