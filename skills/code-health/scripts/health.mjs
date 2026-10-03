#!/usr/bin/env node
// Measures a repo's structural health and its trend.
//
//   health.mjs [path] [--save] [--json] [--top N]
//
// It does not review the diff: code review already does that. It measures **the
// whole**, which is what nobody looks at and what erodes slowly. No
// dependencies: all it needs are files and git.
//
// With --save it stores the baseline. From then on the question stops being
// "is this fine?" and becomes "is it worse than last time?", the only one that
// can be answered without arguing over thresholds.

import { readFileSync, writeFileSync, existsSync, readdirSync, statSync } from 'node:fs'
import { join, relative, extname } from 'node:path'
import { execSync } from 'node:child_process'

const args = process.argv.slice(2)
const ROOT = args.find(a => !a.startsWith('--')) || process.cwd()
const SAVE = args.includes('--save')
const JSON_OUT = args.includes('--json')
const TOP = Number((args.find(a => a.startsWith('--top')) || '').split('=')[1] || 8)
const WITH_TESTS = args.includes('--tests')
const MIN_MASS = Number((args.find(a => a.startsWith('--masa') || a.startsWith('--mass')) || '').split('=')[1] || 200)
const BASELINE = join(ROOT, '.crux-health.json')

const CODE = new Set(['.ts', '.tsx', '.js', '.jsx', '.mjs', '.py', '.go', '.rs', '.java', '.rb'])
const IGNORE = new Set(['node_modules', '.git', 'dist', 'build', '.next', 'coverage',
  'vendor', '__pycache__', '.venv', 'target', 'out', '.turbo', 'migrations'])

function listFiles(dir, acc = []) {
  let entries
  try { entries = readdirSync(dir, { withFileTypes: true }) } catch { return acc }
  for (const e of entries) {
    if (e.name.startsWith('.') && e.name !== '.claude') continue
    if (IGNORE.has(e.name)) continue
    const full = join(dir, e.name)
    const isTest = /(^|\/)(__tests__|tests?|spec)(\/|$)/.test(full) || /\.(test|spec)\.[a-z]+$/.test(e.name)
    if (isTest && !WITH_TESTS) continue
    if (e.isDirectory()) listFiles(full, acc)
    else if (CODE.has(extname(e.name))) acc.push(full)
  }
  return acc
}

// Normalize so that duplication does not depend on formatting or on local
// variable names, which is what makes a textual diff useless.
const normalize = (l) => l.trim().replace(/\s+/g, ' ')
// A line counts if it carries logic of its own. We discard what repeats by
// force of the language (braces, imports, comments) because otherwise the
// report fills with false positives and stops being read.
const structural = (l) =>
  /^[)\]}{;,]+$/.test(l) ||
  /^(import|from|export|package|use|#include)\b/.test(l) ||
  l.startsWith('//') || l.startsWith('#') || /^[*]|^\/\*/.test(l)

const substantive = (l) => l.length >= 15 && !structural(l)

// And with real logic: without this, an object literal or a repeated list of
// fields counts as duplicated code.
const withLogic = (l) =>
  !structural(l) &&
  /\b(if|for|while|return|await|throw|catch|switch|case|function|def|const|let|var)\b|=>|[=<>!+\-*/%&|?]/.test(l)

function duplication(files, window = 6) {
  const blocks = new Map()
  for (const f of files) {
    const lines = readFileSync(f, 'utf8').split('\n').map(normalize)
    for (let i = 0; i + window <= lines.length; i++) {
      const chunk = lines.slice(i, i + window)
      // Minimum mass of own content: a generic error-handling block has few,
      // short substantive lines, and without this threshold it floods the
      // report with the same pattern repeated in every file.
      const mass = chunk.filter(substantive).reduce((n, l) => n + l.length, 0)
      if (mass < MIN_MASS) continue
      if (chunk.filter(withLogic).length < 3) continue
      const key = chunk.join('\u0001')
      if (!blocks.has(key)) blocks.set(key, [])
      blocks.get(key).push({ file: f, line: i + 1 })
    }
  }
  const groups = []
  for (const [key, sites] of blocks) {
    if (sites.length < 2) continue
    // Overlaps inside the same file count once: otherwise a repeated 20-line
    // block appears 15 times and the report stops being useful.
    const seenSet = []
    for (const s of sites) {
      if (seenSet.some(v => v.file === s.file && Math.abs(v.line - s.line) < window)) continue
      seenSet.push(s)
    }
    if (seenSet.length >= 2) groups.push({ lines: window, sites: seenSet, sample: key.split('\u0001')[0] })
  }
  // A duplicated 12-line block shows up here as 7 contiguous windows.
  // Without merging them, the report repeats the same finding seven times and
  // the block's real size, which says how much it hurts, is lost.
  const bySignature = new Map()
  for (const g of groups) {
    const signature = g.sites.map(s => s.file).sort().join('|')
    if (!bySignature.has(signature)) bySignature.set(signature, [])
    bySignature.get(signature).push(g)
  }

  const merged = []
  for (const list of bySignature.values()) {
    list.sort((a, b) => a.sites[0].line - b.sites[0].line)
    let current = null
    for (const g of list) {
      const contiguous = current && g.sites.every((s, i) => {
        const prev = current.sites.find(p => p.file === s.file)
        return prev && s.line - prev.line === current.lines - window + 1
      })
      if (contiguous) current.lines++
      else { if (current) merged.push(current); current = { ...g, sites: [...g.sites] } }
    }
    if (current) merged.push(current)
  }

  return merged.sort((a, b) =>
    (b.sites.length * b.lines) - (a.sites.length * a.lines))
}

function complexity(files) {
  const long = []
  const nested = []
  const decl = /^\s*(export\s+)?(async\s+)?(function|def|func|fn|public|private|protected)?\s*[\w.]*\s*[({]/
  for (const f of files) {
    const lines = readFileSync(f, 'utf8').split('\n')
    let start = null, base = 0, maxDepth = 0
    lines.forEach((l, i) => {
      if (!l.trim()) return
      const depth = Math.floor((l.match(/^[ \t]*/)[0].replace(/\t/g, '  ').length) / 2)
      maxDepth = Math.max(maxDepth, depth)
      if (start === null && decl.test(l) && depth <= 2) { start = i; base = depth }
      else if (start !== null && depth <= base && l.trim() && i > start + 2) {
        const length = i - start
        const body = lines.slice(start, i)
        const branches = body.filter(x => /\b(if|for|while|switch|catch|\?\.|&&|\|\|)\b/.test(x)).length
        // A long block without branches is a data catalog: long is not complex.
        if (length > 60 && branches >= 5) long.push({ file: f, line: start + 1, lines: length, branches })
        start = null
      }
    })
    if (maxDepth >= 7) nested.push({ file: f, depth: maxDepth })
  }
  return { long: long.sort((a, b) => b.lines - a.lines), nested: nested.sort((a, b) => b.depth - a.depth) }
}

function orphanExports(files) {
  const exported = new Map()
  const imported = new Set()
  for (const f of files) {
    const src = readFileSync(f, 'utf8')
    for (const m of src.matchAll(/^export\s+(?:async\s+)?(?:const|function|class|type|interface|enum)\s+(\w+)/gm)) {
      exported.set(m[1], f)
    }
    for (const m of src.matchAll(/import\s+(?:type\s+)?\{([^}]+)\}/g)) {
      for (const n of m[1].split(',')) imported.add(n.trim().split(/\s+as\s+/)[0].trim())
    }
    for (const m of src.matchAll(/import\s+(\w+)\s+from/g)) imported.add(m[1])
  }
  return [...exported].filter(([n]) => !imported.has(n)).map(([n, f]) => ({ name: n, file: f }))
}

function unusedDeps(root, files) {
  const pkg = join(root, 'package.json')
  if (!existsSync(pkg)) return []
  let deps
  try { deps = Object.keys(JSON.parse(readFileSync(pkg, 'utf8')).dependencies || {}) } catch { return [] }
  const src = files.map(f => readFileSync(f, 'utf8')).join('\n')
  return deps.filter(d => !new RegExp(`['"\`]${d.replace(/[/\\^$*+?.()|[\]{}]/g, '\\$&')}(/|['"\`])`).test(src))
}

function churn(root, days = 90) {
  try {
    const out = execSync(`git -C "${root}" log --since="${days} days ago" --numstat --format=""`,
      { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] })
    const count = new Map()
    for (const l of out.split('\n')) {
      const [a, b, f] = l.split('\t')
      if (!f || !CODE.has(extname(f))) continue
      count.set(f, (count.get(f) || 0) + (Number(a) || 0) + (Number(b) || 0))
    }
    return [...count].sort((a, b) => b[1] - a[1]).map(([file, lines]) => ({ file, lines }))
  } catch { return [] }
}

// --- Measurement -------------------------------------------------------------

const files = listFiles(ROOT)
if (!files.length) {
  console.log(`no code files under ${ROOT}`)
  process.exit(0)
}

const rel = (f) => relative(ROOT, f)
const dup = duplication(files)
const { long, nested } = complexity(files)
const orphans = orphanExports(files)
const deps = unusedDeps(ROOT, files)
const changes = churn(ROOT)
const totalLines = files.reduce((n, f) => n + readFileSync(f, 'utf8').split('\n').length, 0)

const metrics = {
  files: files.length,
  lines: totalLines,
  duplicateBlocks: dup.length,
  duplicatedLines: dup.reduce((n, g) => n + g.lines * (g.sites.length - 1), 0),
  longFunctions: long.length,
  deeplyNestedFiles: nested.length,
  unimportedExports: orphans.length,
  unusedDeps: deps.length,
}

// Baselines saved by earlier versions carry Spanish keys; they are still read.
const OLD_METRIC_KEYS = {
  ficheros: 'files', lineas: 'lines', bloquesDuplicados: 'duplicateBlocks',
  lineasDuplicadas: 'duplicatedLines', funcionesLargas: 'longFunctions',
  ficherosMuyAnidados: 'deeplyNestedFiles', exportsSinImportar: 'unimportedExports',
  depsSinUsar: 'unusedDeps',
}
function readBaseline(file) {
  const raw = JSON.parse(readFileSync(file, 'utf8'))
  const stored = raw.metrics || raw.metricas || {}
  const metrics = {}
  for (const [k, v] of Object.entries(stored)) metrics[OLD_METRIC_KEYS[k] || k] = v
  return { date: raw.date || raw.fecha, metrics }
}

if (JSON_OUT) {
  console.log(JSON.stringify({ metrics, dup, long, nested, orphans, deps }, null, 2))
  process.exit(0)
}

// --- Report ------------------------------------------------------------------

const previous = existsSync(BASELINE) ? readBaseline(BASELINE) : null

console.log(`health of ${relative(process.cwd(), ROOT) || '.'} — ${metrics.files} files, ${metrics.lines} lines${WITH_TESTS ? '' : ' (tests excluded, --tests to include them)'}\n`)

if (previous) {
  console.log(`Compared with the baseline (${previous.date}):\n`)
  const rows = Object.entries(metrics).filter(([k]) => !['files', 'lines'].includes(k))
  for (const [k, v] of rows) {
    const before = previous.metrics[k] ?? 0
    const d = v - before
    const signal = d > 0 ? `+${d}` : d < 0 ? String(d) : '='
    console.log(`  ${String(v).padStart(5)}  ${signal.padStart(5)}   ${k}`)
  }
  const worst = rows.filter(([k, v]) => v > (previous.metrics[k] ?? 0))
  console.log(worst.length
    ? `\n  Worse in ${worst.length} of ${rows.length}. What rises for no reason is debt.\n`
    : '\n  Nothing is worse than the baseline.\n')
} else {
  console.log('No baseline. Run with --save to set it and be able to see the trend.\n')
}

const sample = (title, list, fmt) => {
  if (!list.length) return
  console.log(`${title} (${list.length}):\n`)
  for (const x of list.slice(0, TOP)) console.log('  ' + fmt(x))
  if (list.length > TOP) console.log(`  ... and ${list.length - TOP} more`)
  console.log()
}

sample('Duplicated blocks', dup, g =>
  `${g.sites.length}x ${g.lines} lines · ${g.sites.map(s => `${rel(s.file)}:${s.line}`).join('  ')}\n       ${g.sample.slice(0, 68)}`)
sample('Long functions with branches', long, x =>
  `${String(x.lines).padStart(4)} lines · ${String(x.branches).padStart(3)} branches  ${rel(x.file)}:${x.line}`)
sample('Deeply nested files', nested, x => `depth ${x.depth}  ${rel(x.file)}`)
sample('Exports nobody imports', orphans, x => `${x.name.padEnd(28)} ${rel(x.file)}`)
sample('Declared but unused dependencies', deps.map(d => ({ d })), x => x.d)
sample('Most churned files (90 days)', changes, x => `${String(x.lines).padStart(6)} lines  ${x.file}`)

console.log('How to read it:\n')
console.log('  Duplication is the metric that rises most when working with agents: the')
console.log('  model repeats patterns instead of reusing what already exists. A block')
console.log('  in two places may be chance; in four, it is a missing function.')
console.log('  Orphan exports may be public API: check before deleting.')
console.log('  And a file that is both heavily churned and deeply nested is the one that')
console.log('  will cost you most: that is where a refactor is worth it.\n')

if (SAVE) {
  writeFileSync(BASELINE, JSON.stringify({ date: new Date().toISOString().slice(0, 10), metrics }, null, 2) + '\n')
  console.log(`baseline saved to ${relative(process.cwd(), BASELINE)}`)
}
