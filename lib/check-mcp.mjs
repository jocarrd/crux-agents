#!/usr/bin/env node
// Checks the `mcp` block of the contract: that each server is well declared,
// that it carries no credentials written inside, and that what is in the
// .mcp.json files is still what the contract says.
//
// It opens no connection. Checking that a server responds means asking the
// network, and `crux doctor` has to take the same time and say the same thing
// with wifi and without it. `crux mcp status` answers that, and it runs when
// it matters.
//
// Each finding is printed with its severity first: `error` if the resulting
// file would be invalid or a secret is written, `warning` if it has merely
// drifted from what is declared.

import { readFileSync, existsSync } from 'node:fs'
import { join, dirname, basename } from 'node:path'
import { fingerprintsIn } from './credential-prints.mjs'
import { toClientFormat, textsOf, reposOf, TRANSPORTS } from './mcp-format.mjs'

const docs = process.argv[2]
if (!docs) {
  console.error('usage: check-mcp.mjs <docs-repo>')
  process.exit(2)
}

const contractPath = join(docs, 'crux.json')
if (!existsSync(contractPath)) process.exit(0)

let contract
try {
  contract = JSON.parse(readFileSync(contractPath, 'utf8'))
} catch {
  process.exit(0) // an unreadable contract is already reported by doctor's block 1
}

const declared = contract.mcp
if (!declared || !Object.keys(declared).length) process.exit(0)

const findings = []

// The same rule the rest of the kernel applies to names: style is not
// legislated, only what does harm is closed. A name is concatenated into paths
// and expressions, and the first one carrying a double quote executed code when
// reading the contract of a cloned project.
const NAME_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]*$/

// A value without an environment variable reference is a literal, and a literal
// in an authorization header travels to git.
const SENSIBLE = /(authorization|api[-_]?key|token|secret|password|bearer)/i

for (const [name, d] of Object.entries(declared)) {
  if (!NAME_PATTERN.test(name) || name.includes('..')) {
    findings.push(
      `error '${name}' is not valid as a server name — letters, digits, dot, hyphen and underscore`,
    )
    continue
  }

  const transport = d.transport || 'stdio'
  if (!TRANSPORTS.includes(transport)) {
    findings.push(`error ${name}: transport '${transport}' — only ${TRANSPORTS.join(', ')}`)
    continue
  }

  // The shape is decided by whoever writes it, so that doctor and adapter cannot
  // disagree about what is valid.
  try {
    toClientFormat(name, d)
  } catch (e) {
    findings.push(`error ${e.message}`)
  }

  if (transport === 'stdio' && d.url) {
    findings.push(`warning ${name}: 'url' is not used with transport stdio`)
  }
  if (transport !== 'stdio' && (d.command || d.args)) {
    findings.push(`warning ${name}: 'command'/'args' are not used with transport ${transport}`)
  }

  for (const { where, text, key } of textsOf(d)) {
    for (const fingerprint of fingerprintsIn(text)) {
      findings.push(`error ${name}: ${fingerprint} written in ${where}`)
    }
    if (key && SENSIBLE.test(key) && !text.includes('${')) {
      findings.push(
        `error ${name}: ${where} carries a literal value — use \${VARIABLE}, the file is committed`,
      )
    }
  }
}

// Drift in both directions. Looking only at what is extra in the file let what
// is missing pass —a freshly cloned machine has none— and, worse, a value
// changed by hand: doctor signed off as conforming a .mcp.json whose url
// pointed elsewhere.
const root = dirname(docs)

// Where there should be a file, according to what each server asks for. A repo
// that is not cloned does not count: doctor's block 3 already warns about that.
const expectedList = new Set([docs])
for (const n of Object.keys(declared)) {
  for (const r of reposOf(contract, n)) {
    if (existsSync(join(root, r))) expectedList.add(join(root, r))
  }
}

for (const dir of [docs, ...(contract.repos || []).map((r) => join(root, r))]) {
  const file = join(dir, '.mcp.json')
  const label = basename(dir)
  if (!existsSync(file)) {
    if (expectedList.has(dir)) {
      findings.push(`warning ${label} has no .mcp.json — run 'crux mcp install'`)
    }
    continue
  }

  let rank
  try {
    rank = JSON.parse(readFileSync(file, 'utf8'))
  } catch (e) {
    findings.push(`error ${label}/.mcp.json unreadable: ${e.message}`)
    continue
  }
  const servers = rank.mcpServers || {}

  for (const n of Object.keys(servers)) {
    if (!declared[n]) {
      findings.push(`warning ${label}/.mcp.json has '${n}', which the contract does not declare`)
    }
  }
  for (const [n, d] of Object.entries(declared)) {
    if (!servers[n]) continue
    let expected
    try {
      expected = toClientFormat(n, d)
    } catch {
      continue // already reported above as a shape error
    }
    if (JSON.stringify(servers[n]) !== JSON.stringify(expected)) {
      findings.push(
        `warning ${label}/.mcp.json has '${n}' different from what is declared — 'crux mcp install'`,
      )
    }
  }
}

for (const h of findings) console.log(h)
process.exit(0)
