#!/usr/bin/env node
// Drift check for a docs repo.
//
// For each .md in the repo, extracts the references to local files and
// verifies that they exist. Designed to minimize false positives:
//
//  - Ignores code inside ``` ``` blocks (they are examples, not real links)
//  - Only verifies markdown links [text](path), not inline backticks
//    (backticks in prose are usually illustrative, not navigable)
//  - Resolves paths relative to the file that contains the link
//  - Skips http(s) URLs and bare anchors (#section)
//
// Usage:
//   node scripts/check-doc-paths.mjs          # checks the whole repo
//   node scripts/check-doc-paths.mjs <path>   # checks a file or subdir
//
// Exits with code 1 if there are misses, 0 if everything resolves.

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
  // Replaces fenced code blocks AND inline code with spaces of the same length
  // (preserving newlines and offsets) so the link regex does not match inside
  // syntax examples or code.
  let out = md.replace(/```[\s\S]*?```/g, (m) => m.replace(/[^\n]/g, ' '))
  out = out.replace(/`[^`\n]+`/g, (m) => ' '.repeat(m.length))
  return out
}

function extractLinks(md) {
  // [text](url) — captures url
  const re = /\[([^\]]+)\]\(([^)\s]+)\)/g
  const out = []
  let m
  while ((m = re.exec(md))) {
    const url = m[2]
    if (url.startsWith('http://') || url.startsWith('https://')) continue
    if (url.startsWith('#')) continue
    if (url.startsWith('mailto:')) continue
    // Split off the anchor: foo.md#section → foo.md
    const cleanUrl = url.split('#')[0]
    if (!cleanUrl) continue
    // Approximate line position for reporting
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
// Paths are shown from the docs repo being checked, not from the kernel:
// relative to the latter they came out as ../../../../<the whole way>.
const BASE = statSync(TARGET).isDirectory() ? TARGET : dirname(TARGET)

let totalMisses = 0
for (const f of files) {
  const misses = checkFile(f)
  if (misses.length === 0) continue
  const rel = relative(BASE, f)
  console.log(`\n${rel}:`)
  for (const { url, line, target } of misses) {
    console.log(`  L${line}: ${url}`)
    console.log(`         → ${relative(BASE, target)} (does not exist)`)
    totalMisses++
  }
}

console.log(`\n${totalMisses === 0 ? '✔' : '✘'} ${totalMisses} ${totalMisses === 1 ? 'broken link' : 'broken links'} in ${files.length} files.`)
process.exit(totalMisses === 0 ? 0 : 1)
