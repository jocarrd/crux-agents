#!/usr/bin/env node
// One-shot fix-up: removes markdown links that point OUTSIDE this docs repo.
//
// Rule of the standard: markdown links are only allowed between files inside
// the docs repo itself (where we know they resolve). Links to code in sibling
// repos or to paths that do not exist in this repo are removed: the path is
// preserved as text (backticked or descriptive) but without the link syntax,
// which is what breaks when files are moved.
//
// Rules:
//   - `[X](path)` where path resolves inside the docs repo  → keep link
//   - `[X](path)` where path is outside (../<repo>/..., etc.) → just X
//   - `[X](http(s)://...)`                                    → keep link
//   - `[X](#anchor)`                                          → keep link
//   - `[X](mailto:...)`                                       → keep link
//
// Also applies to SKILL.md inside .claude/skills/. Respects inline code
// `[text](path)` (syntax examples) and ``` code blocks — those are never
// modified.
//
// Usage:
//   node scripts/fix-doc-paths.mjs            # applies changes
//   node scripts/fix-doc-paths.mjs --dry-run  # shows what it would do without writing
//   node scripts/fix-doc-paths.mjs -n         # alias of --dry-run

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

// Returns the string with the inline code and code block ranges replaced by
// spaces (preserving newlines and length). This leaves the offsets intact, so
// a regex over the "masked" version does not match inside code but the indices
// match the original.
function maskCodeSpans(md) {
  let out = md
  // Fenced blocks
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

  // Search for matches over `masked` but use offsets to rewrite `original`.
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
  console.log(`\n=== DRY RUN — nothing has been written ===\n`)
  for (const [file, changes] of changesByFile) {
    console.log(`${relative(ROOT, file)}:`)
    for (const { line, from, to } of changes) {
      console.log(`  L${line}: ${from}`)
      console.log(`         →  ${to}`)
    }
    console.log()
  }
  console.log(
    `${totalStripped} link(s) would be removed, ${totalKept} would be kept. ` +
      `Run without --dry-run to apply.`,
  )
} else {
  console.log(
    `\n${totalStripped} external link(s) removed, ${totalKept} valid link(s) kept.`,
  )
}
