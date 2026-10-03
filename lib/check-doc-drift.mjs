#!/usr/bin/env node
// Measures the distance between what has moved in the code and what has been
// written in the documentation.
//
// It does not claim to know WHAT is missing from the docs — that is not
// measurable from git. What is measurable is whether the code has been moving
// for a while without the docs moving, and that is enough to raise a hand.
//
//   check-doc-drift.mjs <docs-repo> [--json]
//
// Always exits 0: the caller decides whether it is a warning, an error or a
// reminder.

import { readFileSync, existsSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import { dirname, join, basename } from 'node:path'

const docs = process.argv[2]
const asJson = process.argv.includes('--json')

if (!docs) {
  console.error('usage: check-doc-drift.mjs <docs-repo> [--json]')
  process.exit(2)
}

function git(dir, args) {
  try {
    return execFileSync('git', ['-C', dir, ...args], {
      encoding: 'utf-8',
      stdio: ['ignore', 'pipe', 'ignore'],
    }).trim()
  } catch {
    return ''
  }
}

function lastCommit(dir) {
  const ts = git(dir, ['log', '-1', '--format=%ct'])
  return ts ? Number(ts) : 0
}

// Strictly later: a code commit in the same second as the documentation one is
// the good case —it was documented in the same turn—, not drift.
function countSince(dir, since) {
  if (!since) return 0
  const out = git(dir, ['rev-list', '--count', `--since=@${since + 1}`, 'HEAD'])
  return out ? Number(out) : 0
}

// In the code repo, untracked files are usually build noise. In the
// documentation repo it is the opposite: a new untracked file is freshly
// written documentation that is not yet anywhere durable, which is exactly
// what this watches.
function dirty(dir, { includeNew = false } = {}) {
  const out = git(dir, ['status', '--porcelain'])
  if (!out) return 0
  return out.split('\n').filter((l) => {
    if (!l.trim()) return false
    if (!l.startsWith('??')) return true
    return includeNew && l.trim().endsWith('.md')
  }).length
}

const projectRoot = dirname(docs)
let contract = {}
try {
  contract = JSON.parse(readFileSync(join(docs, 'crux.json'), 'utf-8'))
} catch {
  // Without a contract there is no repo list; carry on with what can be deduced.
}

const repos = Array.isArray(contract.repos) ? contract.repos : []
const docsLast = lastCommit(docs)
const dirtyDocs = dirty(docs, { includeNew: true })

const findings = []
let codeCommits = 0
let mostRecentRepo = 0

for (const repo of repos) {
  const dir = join(projectRoot, repo)
  if (!existsSync(join(dir, '.git'))) continue

  const last = lastCommit(dir)
  if (!last) continue
  if (last > mostRecentRepo) mostRecentRepo = last

  const n = countSince(dir, docsLast)
  const pendingProjects = dirty(dir)
  if (n === 0 && pendingProjects === 0) continue

  codeCommits += n
  findings.push({
    repo,
    commits: n,
    uncommitted: pendingProjects,
    last: new Date(last * 1000).toISOString().slice(0, 10),
  })
}

const days = docsLast
  ? Math.floor((Date.now() / 1000 - docsLast) / 86400)
  : null

const summary = {
  docsLastCommit: docsLast
    ? new Date(docsLast * 1000).toISOString().slice(0, 10)
    : null,
  docsDaysUntouched: days,
  docsUncommitted: dirtyDocs,
  codeCommitsWithoutDocs: codeCommits,
  repos: findings,
}

if (asJson) {
  console.log(JSON.stringify(summary))
  process.exit(0)
}

for (const h of findings) {
  const parts = []
  if (h.commits) {
    parts.push(
      `${h.commits} commit${h.commits === 1 ? '' : 's'} since the last docs one`,
    )
  }
  if (h.uncommitted) {
    parts.push(
      `${h.uncommitted} file${h.uncommitted === 1 ? '' : 's'} uncommitted`,
    )
  }
  console.log(`${h.repo}: ${parts.join(', ')} (last: ${h.last})`)
}

if (dirtyDocs) {
  console.log(
    `${basename(docs)}: ${dirtyDocs} documentation file${dirtyDocs === 1 ? '' : 's'} uncommitted`,
  )
}

process.exit(0)
