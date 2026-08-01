#!/usr/bin/env node
// Drift check de un docs repo.
//
// Para cada .md en el repo, extrae las referencias a archivos locales y
// verifica que existen. Diseñado para minimizar falsos positivos:
//
//  - Ignora código dentro de bloques ``` ``` (son ejemplos, no links reales)
//  - Solo verifica markdown links [text](path), no inline backticks
//    (los backticks en prosa suelen ser ilustrativos, no navegables)
//  - Resuelve paths relativos al archivo que contiene el link
//  - Saltarse URLs http(s) y anchors solo (#section)
//
// Uso:
//   node scripts/check-doc-paths.mjs          # comprueba todo el repo
//   node scripts/check-doc-paths.mjs <path>   # comprueba un archivo o subdir
//
// Sale con código 1 si hay misses, 0 si todo resuelve.

import { readFileSync, statSync, readdirSync, existsSync } from 'node:fs'
import { resolve, dirname, join, relative } from 'node:path'

const ROOT = resolve(new URL('..', import.meta.url).pathname)
const TARGET = process.argv[2] ? resolve(process.argv[2]) : ROOT

function walkMarkdown(dir) {
  const out = []
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    if (entry.name.startsWith('.')) continue
    if (entry.name === 'node_modules') continue
    const full = join(dir, entry.name)
    if (entry.isDirectory()) out.push(...walkMarkdown(full))
    else if (entry.name.endsWith('.md')) out.push(full)
  }
  return out
}

function stripCodeBlocks(md) {
  // Reemplaza fenced code blocks Y inline code por espacios de la misma
  // longitud (preservando newlines y offsets) para que la regex de links no
  // matchee dentro de ejemplos de sintaxis ni código.
  let out = md.replace(/```[\s\S]*?```/g, (m) => m.replace(/[^\n]/g, ' '))
  out = out.replace(/`[^`\n]+`/g, (m) => ' '.repeat(m.length))
  return out
}

function extractLinks(md) {
  // [text](url) — captura url
  const re = /\[([^\]]+)\]\(([^)\s]+)\)/g
  const out = []
  let m
  while ((m = re.exec(md))) {
    const url = m[2]
    if (url.startsWith('http://') || url.startsWith('https://')) continue
    if (url.startsWith('#')) continue
    if (url.startsWith('mailto:')) continue
    // Separar anchor: foo.md#section → foo.md
    const cleanUrl = url.split('#')[0]
    if (!cleanUrl) continue
    // Posición aproximada de línea para reportar
    const before = md.slice(0, m.index)
    const line = before.split('\n').length
    out.push({ url: cleanUrl, line })
  }
  return out
}

function checkFile(filePath) {
  const md = stripCodeBlocks(readFileSync(filePath, 'utf8'))
  const links = extractLinks(md)
  const misses = []
  for (const { url, line } of links) {
    const target = resolve(dirname(filePath), url)
    if (!existsSync(target)) {
      misses.push({ url, line, target })
    }
  }
  return misses
}

const files = statSync(TARGET).isDirectory() ? walkMarkdown(TARGET) : [TARGET]

let totalMisses = 0
for (const f of files) {
  const misses = checkFile(f)
  if (misses.length === 0) continue
  const rel = relative(ROOT, f)
  console.log(`\n${rel}:`)
  for (const { url, line, target } of misses) {
    console.log(`  L${line}: ${url}`)
    console.log(`         → ${relative(ROOT, target)} (no existe)`)
    totalMisses++
  }
}

console.log(`\n${totalMisses === 0 ? '✔' : '✘'} ${totalMisses} link(s) rotos en ${files.length} archivos.`)
process.exit(totalMisses === 0 ? 0 : 1)
