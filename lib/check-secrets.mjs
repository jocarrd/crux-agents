#!/usr/bin/env node
import { readFileSync } from 'node:fs'
import { globSync } from 'node:fs'
import { join, relative } from 'node:path'
import { FINGERPRINTS } from './credential-prints.mjs'

const docs = process.argv[2]
if (!docs) {
  console.error('usage: check-secrets.mjs <docs-repo>')
  process.exit(2)
}


// A loose password inside a code block has no format to recognize, so its
// shape is examined: long, without spaces and mixing character classes. Hashes
// and identifiers are left out because they are of a single class, and example
// ones because they name themselves.
const EXAMPLE = /(changeme|example|ejemplo|demo|dev|test|password|contrasena|contraseña|secret|xxxx|placeholder|your|tu-)/i
const HEX = /^[0-9a-f]+$/i

// The value of an assignment: no odd signs, a mix of upper case, lower case and
// digits, and long enough not to be a word.
function looksLikeValue(v) {
  if (v.length < 12 || v.length > 128) return false
  if (/[:/@\\]/.test(v)) return false
  if (!/[a-z]/.test(v) || !/[A-Z]/.test(v) || !/[0-9]/.test(v)) return false
  if (/^(changeme|example|placeholder|password|secret|tu-|your-|xxx)/i.test(v)) return false
  return true
}

// KEY=value is the number one way of pasting a secret into a document, and
// discarding on the `=` let it through entirely. It is checked outside and
// inside code blocks: a pasted .env almost never carries the block fences.
function assignmentWithSecret(line) {
  const m = line.trim().match(/^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*["']?([^"'\s]+)["']?$/)
  if (!m) return false
  if (!/(PASS|PASSWORD|SECRET|TOKEN|KEY|CREDENTIAL|AUTH|API)/i.test(m[1])) return false
  return looksLikeValue(m[2])
}

function looksLikePassword(line) {
  const s = line.trim()
  if (s.length < 12 || s.length > 64 || /\s/.test(s)) return false
  if (EXAMPLE.test(s) || HEX.test(s)) return false
  // Syntax, not credentials: JSON, config files, paths, code.
  if (/["'`:=,{}()[\]<>;|\/.@\\]/.test(s)) return false
  const classes =
    (/[a-z]/.test(s) ? 1 : 0) +
    (/[A-Z]/.test(s) ? 1 : 0) +
    (/[0-9]/.test(s) ? 1 : 0)
  return classes >= 3
}

const findings = []
let files = []
try {
  // Besides the documentation, the .mcp.json files: they are generated from the
  // contract, committed and read by nobody, which is the combination by which a
  // token ends up in the history without anyone noticing.
  files = globSync(['**/*.md', '**/.mcp.json'], { cwd: docs }).filter(
    (f) => !f.startsWith('.git/'),
  )
} catch {
  files = []
}

for (const rel of files.sort()) {
  const lines = readFileSync(join(docs, rel), 'utf-8').split('\n')
  let inBlock = false
  lines.forEach((line, i) => {
    if (line.trimStart().startsWith('```')) {
      inBlock = !inBlock
      return
    }
    for (const { name, rx } of FINGERPRINTS) {
      if (rx.test(line)) findings.push(`${rel}:${i + 1} ${name}`)
    }
    if (inBlock && looksLikePassword(line)) {
      findings.push(`${rel}:${i + 1} possible loose password`)
    } else if (assignmentWithSecret(line)) {
      findings.push(`${rel}:${i + 1} possible credential in an assignment`)
    }
  })
}

for (const h of findings) console.log(h)
process.exit(0)
