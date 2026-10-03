#!/usr/bin/env node
import { readFileSync, globSync } from 'node:fs'
import { join } from 'node:path'

const docs = process.argv[2]
const months = Number(process.argv[3] || 6)
if (!docs) {
  console.error('usage: check-staleness.mjs <docs-repo> [months]')
  process.exit(2)
}

// Only what is executed. In architecture/ or conventions/ staleness shows when
// reading; in operations/ it shows when the command fails with the system
// down.
let files = []
try {
  files = globSync('operations/**/*.md', { cwd: docs })
} catch {
  files = []
}

const limit = Date.now() - months * 30 * 24 * 3600 * 1000
const MARKER = /^>\s*(?:Última verificación|Last verified):\s*(\d{4}-\d{2}-\d{2})\s*$/m

for (const rel of files.sort()) {
  const text = readFileSync(join(docs, rel), 'utf-8')
  const m = text.match(MARKER)
  if (!m) continue
  const date = Date.parse(m[1])
  if (Number.isNaN(date)) {
    console.log(`${rel} has a verification date that cannot be understood: ${m[1]}`)
    continue
  }
  if (date < limit) {
    const days = Math.round((Date.now() - date) / (24 * 3600 * 1000))
    console.log(`${rel} unverified for ${days} days`)
  }
}
process.exit(0)
