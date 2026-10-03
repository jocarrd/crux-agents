#!/usr/bin/env node
// Translates the contract's `mcp` block into the file Claude Code reads.
//
//   mcp.mjs write <crux.json> <target>   writes/updates <target>/.mcp.json
//   mcp.mjs clear <crux.json> <target>   removes only what the contract declares
//   mcp.mjs diff  <crux.json> <target>   what is set versus what is declared
//
// The contract is the source of truth and the client file is a derivative: what
// is declared is rewritten, what someone put by hand is respected and what is
// left over is reported instead of deleted. Deleting foreign configuration
// because it does not appear in our contract would be the same mistake that
// `crux hooks remove` avoids by removing only its own.

import { readFileSync, writeFileSync, existsSync, unlinkSync } from 'node:fs'
import { join } from 'node:path'
import { toClientFormat } from '../../lib/mcp-format.mjs'

const [action, contractPath, target] = process.argv.slice(2)
if (!action || !contractPath || !target) {
  console.error('usage: mcp.mjs write|clear|diff <crux.json> <target>')
  process.exit(2)
}

const filePath = join(target, '.mcp.json')
const declared = JSON.parse(readFileSync(contractPath, 'utf8')).mcp || {}

// A corrupt file is not overwritten silently: it is someone's configuration,
// and the caller needs to find out through the exit code.
let current = { mcpServers: {} }
if (existsSync(filePath)) {
  try {
    current = JSON.parse(readFileSync(filePath, 'utf8'))
  } catch (e) {
    console.error(`.mcp.json unreadable (${e.message}) — left untouched`)
    process.exit(1)
  }
  current.mcpServers = current.mcpServers || {}
}

const names = Object.keys(declared)
const foreign = Object.keys(current.mcpServers).filter((n) => !names.includes(n))

if (action === 'diff') {
  for (const n of names) {
    const expected = JSON.stringify(toClientFormat(n, declared[n]))
    const current_entry = current.mcpServers[n] ? JSON.stringify(current.mcpServers[n]) : null
    if (!current_entry) console.log(`missing ${n}`)
    else if (current_entry !== expected) console.log(`differs ${n}`)
    else console.log(`ok ${n}`)
  }
  for (const n of foreign) console.log(`foreign ${n}`)
  process.exit(0)
}

if (action === 'clear') {
  for (const n of names) delete current.mcpServers[n]
  // A file that only contained what is ours goes away entirely: leaving an
  // orphan `{"mcpServers":{}}` is noise in the git status of whoever clones.
  if (!Object.keys(current.mcpServers).length && Object.keys(current).length === 1) {
    if (existsSync(filePath)) unlinkSync(filePath)
    console.log('borrado')
  } else {
    writeFileSync(filePath, JSON.stringify(current, null, 2) + '\n')
    console.log(`retirados ${names.length}`)
  }
  process.exit(0)
}

if (action === 'write') {
  if (!names.length) {
    console.log('the contract declares none')
    process.exit(0)
  }
  for (const n of names) current.mcpServers[n] = toClientFormat(n, declared[n])
  writeFileSync(filePath, JSON.stringify(current, null, 2) + '\n')
  console.log(`written ${names.length}${foreign.length ? ` (${foreign.length} foreign left intact)` : ''}`)
  process.exit(0)
}

console.error(`unknown action: ${action}`)
process.exit(2)
