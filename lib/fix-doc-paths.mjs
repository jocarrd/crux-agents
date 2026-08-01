#!/usr/bin/env node
// One-shot fix-up: elimina markdown links que apunten FUERA de este docs repo.
//
// Regla del estándar: los markdown links solo se permiten entre archivos
// dentro del propio docs repo (donde sabemos que resuelven). Links a código
// de repos hermanos o a paths que no existen en este repo se eliminan: el
// path se preserva como texto (backticked o descriptivo) pero sin la sintaxis
// de link, que es lo que se rompe al mover archivos.
//
// Reglas:
//   - `[X](path)` donde path resuelve dentro del docs repo  → conservar link
//   - `[X](path)` donde path está fuera (../<repo>/..., etc.) → solo X
//   - `[X](http(s)://...)`                                    → conservar link
//   - `[X](#anchor)`                                          → conservar link
//   - `[X](mailto:...)`                                       → conservar link
//
// Aplica también a SKILL.md dentro de .claude/skills/. Respeta inline code
// `[texto](path)` (ejemplos de sintaxis) y bloques de código ``` — esos
// nunca se modifican.
//
// Uso:
//   node scripts/fix-doc-paths.mjs            # aplica cambios
//   node scripts/fix-doc-paths.mjs --dry-run  # muestra qué haría sin escribir
//   node scripts/fix-doc-paths.mjs -n         # alias de --dry-run

import { readFileSync, writeFileSync, readdirSync, existsSync } from 'node:fs'
import { resolve, dirname, join, relative } from 'node:path'

const DRY_RUN = process.argv.includes('--dry-run') || process.argv.includes('-n')
const ROOT = resolve(new URL('..', import.meta.url).pathname)

function walkMd(dir, out = []) {
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    if (e.name === '.git' || e.name === 'node_modules') continue
    const f = join(dir, e.name)
    if (e.isDirectory()) walkMd(f, out)
    else if (e.name.endsWith('.md')) out.push(f)
  }
  return out
}

// Devuelve la cadena con los rangos de inline code y bloques de código
// reemplazados por espacios (preservando newlines y longitud). Esto deja
// los offsets intactos, así una regex sobre la versión "masked" no matchea
// dentro de código pero los índices coinciden con el original.
function maskCodeSpans(md) {
  let out = md
  // Bloques fenced
  out = out.replace(/```[\s\S]*?```/g, (m) => m.replace(/[^\n]/g, ' '))
  // Inline code (single backticks)
  out = out.replace(/`[^`\n]+`/g, (m) => ' '.repeat(m.length))
  return out
}

let totalStripped = 0
let totalKept = 0
const changesByFile = new Map()

const files = walkMd(ROOT)

for (const f of files) {
  const original = readFileSync(f, 'utf8')
  const masked = maskCodeSpans(original)
  const fileChanges = []
  let modified = false

  // Buscar matches sobre `masked` pero usar offsets para reescribir `original`.
  let out = ''
  let lastEnd = 0
  const linkRe = /\[([^\]]+)\]\(<?([^)>\s]+)>?\)/g
  let m

  while ((m = linkRe.exec(masked))) {
    const [match, text, url] = m
    const offset = m.index
    out += original.slice(lastEnd, offset)

    let replacement = match
    let stripped = false

    if (
      url.startsWith('http://') ||
      url.startsWith('https://') ||
      url.startsWith('#') ||
      url.startsWith('mailto:')
    ) {
      totalKept++
    } else {
      const cleanUrl = url.split('#')[0]
      const target = resolve(dirname(f), cleanUrl)
      if (target.startsWith(ROOT + '/') && existsSync(target)) {
        totalKept++
      } else {
        totalStripped++
        stripped = true
        replacement = text
        modified = true
        const line = original.slice(0, offset).split('\n').length
        fileChanges.push({ line, from: match, to: text })
      }
    }

    out += replacement
    lastEnd = offset + match.length
  }
  out += original.slice(lastEnd)

  if (modified) {
    changesByFile.set(f, fileChanges)
    if (!DRY_RUN) {
      writeFileSync(f, out)
      console.log(`✓ ${relative(ROOT, f)}`)
    }
  }
}

if (DRY_RUN) {
  console.log(`\n=== DRY RUN — no se ha escrito nada ===\n`)
  for (const [file, changes] of changesByFile) {
    console.log(`${relative(ROOT, file)}:`)
    for (const { line, from, to } of changes) {
      console.log(`  L${line}: ${from}`)
      console.log(`         →  ${to}`)
    }
    console.log()
  }
  console.log(
    `${totalStripped} link(s) se eliminarían, ${totalKept} se conservarían. ` +
      `Ejecuta sin --dry-run para aplicar.`,
  )
} else {
  console.log(
    `\n${totalStripped} link(s) externos eliminados, ${totalKept} link(s) válidos conservados.`,
  )
}
