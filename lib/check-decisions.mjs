#!/usr/bin/env node
import { readFileSync, existsSync } from 'node:fs'
import { join, relative } from 'node:path'
import { globSync } from 'node:fs'

const docs = process.argv[2]
if (!docs) {
  console.error('usage: check-decisions.mjs <docs-repo>')
  process.exit(2)
}

const SPLIT_THRESHOLD = 30
const PLAIN = new Set(['Open', 'Proposed', 'Accepted', 'Inherited', 'Deprecated'])
const WITH_REF = ['Superseded', 'Amended']

function ledgers() {
  const found = []
  const index = join(docs, 'decisions', 'index.md')
  if (existsSync(index)) found.push(index)
  let repos = []
  try {
    repos = globSync('repos/*/decisions.md', { cwd: docs })
  } catch {
    repos = []
  }
  for (const rel of repos.sort()) found.push(join(docs, rel))
  return found
}

// Templates live inside ``` blocks in the ledger itself: an example
// `- **Status**: Proposed | Accepted` is not a violation.
function entries(file) {
  const out = []
  let adr = null
  let fenced = false
  let commented = false
  const lines = readFileSync(file, 'utf-8').split('\n')
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]
    if (line.startsWith('```')) {
      fenced = !fenced
      continue
    }
    if (line.includes('<!--')) commented = true
    if (commented) {
      if (line.includes('-->')) commented = false
      continue
    }
    if (fenced) continue
    const head = line.match(/^### ADR-(\d+)\s*:/)
    if (head) {
      adr = { num: head[1], line: i + 1, title: line.slice(4).trim(), status: null }
      out.push(adr)
      continue
    }
    const status = line.match(/^-\s+\*\*Status\*\*:\s*(.+?)\s*$/)
    if (status && adr && adr.status === null) adr.status = status[1]
  }
  return out
}

function refTargets(status) {
  return [...status.matchAll(/((?:[\w.-]+\/)*)ADR-(\d+)/g)].map((m) => ({
    prefix: m[1].replace(/\/$/, ''),
    num: m[2],
  }))
}

function resolve(ref, fromFile) {
  if (!ref.prefix) return fromFile
  const candidates = [
    join(docs, ref.prefix, 'index.md'),
    join(docs, ref.prefix, 'decisions.md'),
    join(docs, `${ref.prefix}.md`),
  ]
  return candidates.find(existsSync) ?? null
}

const problems = []
const notes = []

for (const file of ledgers()) {
  const where = relative(docs, file)
  const found = entries(file)

  // The warning goes away once the ledger opens with its table: a warning that
  // stays after being complied with teaches people to ignore warnings.
  const hasToc = /^\|\s*ADR-\d+\s*\|/m.test(readFileSync(file, 'utf-8'))
  if (where === 'decisions/index.md' && found.length > SPLIT_THRESHOLD && !hasToc) {
    notes.push(
      `${where}: ${found.length} ADRs — over ${SPLIT_THRESHOLD}, open the ledger with a table of contents`,
    )
  }

  const seen = new Map()
  for (const adr of found) {
    if (seen.has(adr.num)) {
      problems.push(
        `${where}:${adr.line} duplicate ADR: ADR-${adr.num} (already on line ${seen.get(adr.num)}) — renumber the newest`,
      )
    } else {
      seen.set(adr.num, adr.line)
    }
  }

  for (const adr of found) {
    if (adr.status === null) {
      problems.push(`${where}:${adr.line} ADR-${adr.num} has no Status`)
      continue
    }

    const keyword = WITH_REF.find((k) => adr.status.startsWith(k))
    if (!keyword) {
      if (!PLAIN.has(adr.status)) {
        problems.push(
          `${where}:${adr.line} ADR-${adr.num} unrecognized Status: "${adr.status}"`,
        )
      }
      continue
    }

    const rest = adr.status.slice(keyword.length).replace(/^\s*by\b/, '')
    const refs = refTargets(rest)
    if (refs.length === 0) {
      problems.push(
        `${where}:${adr.line} ADR-${adr.num} "${keyword}" without saying which — the chain breaks there`,
      )
      continue
    }

    // What is left after the references is prose: the why lives in the new ADR.
    const tail = rest
      .replace(/((?:[\w.-]+\/)*)ADR-\d+/g, '')
      .replace(/\band\b/g, ' ')
      .replace(/[\s,y]+/g, '')
    if (tail.length > 0) {
      problems.push(
        `${where}:${adr.line} ADR-${adr.num} Status carries prose besides the state — move it to Consequences`,
      )
    }

    for (const ref of refs) {
      const target = resolve(ref, file)
      if (!target) {
        problems.push(
          `${where}:${adr.line} ADR-${adr.num} points to "${ref.prefix}/ADR-${ref.num}" and that ledger does not exist`,
        )
        continue
      }
      const exists = entries(target).some((e) => e.num === ref.num)
      if (!exists) {
        problems.push(
          `${where}:${adr.line} ADR-${adr.num} points to ADR-${ref.num} in ${relative(docs, target)} and it is not there`,
        )
      }
    }
  }
}

for (const n of notes) console.log(`warning: ${n}`)
for (const p of problems) console.log(p)
process.exit(problems.length > 0 ? 1 : 0)
