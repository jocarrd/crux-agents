#!/usr/bin/env node
// Which skill would activate for a sentence, and by how much it wins.
//
//   probe.mjs "the sentence you would use to ask for the job"
//   probe.mjs --cases [file]           runs a file of cases and reports failures
//                                      (--casos also works)
//   probe.mjs --adaptador <skill> <kernel> "generic sentence" "own sentence"
//                                      checks that an adapter splits with what it adapts
//                                      (--adapter also works)
//
// The rest of the system is verified: structure with doctor, the change with
// the gate, the commit language with a hook. Activation was the only thing
// taken on trust, and it decides whether everything else gets used at all.
//
// This does NOT predict what the agent will do. It scores the vocabulary
// overlap between the sentence and each description, weighting the catalog's
// rare words. It serves what is needed: comparing two wordings and seeing
// whether a regression has switched a skill off. A tie here is a reliable
// signal that two descriptions cannot be told apart; a winner does not
// guarantee it wins for real.

import { readFileSync, existsSync, readdirSync, statSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const EMPTY = new Set(`de la el en y a los las del un una para con por que se su al lo como más o pero sus
le ya esto si porque esta entre muy sin sobre también me hasta hay donde quien desde todo nos durante todos
uno les ni contra otros ese eso ante ellos esa the and for with when this that from your usa use usar invoca
cuando`.split(/\s+/))

// Words are compared as they are, without trimming endings. Two stemmers were
// tried (one for verb suffixes, one for plurals only) and both WORSENED the
// measure over the same 24 cases: from 2 failures to 3, with
// `oauth-reauthorize` winning a session-closing sentence. They merge roots that
// are not the same and create false collisions, which is worse than the problem
// they solved. If retried, measure against `casos/activacion.tsv` first.
//
// The known price: "merece" and "merecen" count as different words.

function words(s) {
  return (s || '')
    .toLowerCase()
    .replace(/[^\p{L}\p{N}\s-]/gu, ' ')
    .split(/\s+/)
    .filter(w => w.length > 3 && !EMPTY.has(w))
}

function description(text) {
  const m = text.match(/^description:\s*([\s\S]*?)(?=\n[a-z_-]+:|\n---)/m)
  return m ? m[1].replace(/\s+/g, ' ').trim() : ''
}

// The catalog the agent sees, not the one in the repos: what matters is what
// it really competes against.
function catalog() {
  const dir = process.env.CLAUDE_SKILLS_DIR || join(process.env.HOME, '.claude', 'skills')
  const output = new Map()
  if (!existsSync(dir)) return output
  for (const n of readdirSync(dir)) {
    const f = join(dir, n, 'SKILL.md')
    try {
      if (statSync(f).isFile()) output.set(n, new Set(words(description(readFileSync(f, 'utf8')))))
    } catch {
      // broken link: reported by `crux doctor --machine`
    }
  }
  return output
}

const SKILLS = catalog()
if (!SKILLS.size) {
  console.error('no installed skills to consult')
  process.exit(1)
}

// A word that appears in forty descriptions distinguishes nothing; one that
// appears in one distinguishes everything. With `log(1 + N/df)` that did not
// hold: what is in all of them still weighed, and the listing filled with
// skills sharing only a template word. `log(N/df)` takes that case to zero.
const inHowMany = new Map()
for (const ws of SKILLS.values()) for (const w of ws) inHowMany.set(w, (inHowMany.get(w) || 0) + 1)
const N = SKILLS.size

function score(sentence) {
  const q = new Set(words(sentence))
  const r = []
  for (const [name, ws] of SKILLS) {
    let s = 0
    for (const w of q) if (ws.has(w)) s += Math.log(N / inHowMany.get(w))
    if (s > 0) r.push({ name, point: +s.toFixed(2) })
  }
  return r.sort((a, b) => b.point - a.point)
}

// Below this two descriptions cannot be told apart: which one wins depends on
// the luck of one word, not on what they say. It is a fraction of the leader
// and not an absolute value, because the score grows with the number of words
// in the sentence: 0.5 was a lot for "revisar la propuesta" and almost nothing
// for a twelve-word sentence, and the cases in the file have both lengths.
const MIN_MARGIN = 0.15

function relativeMargin(r) {
  if (r.length < 2 || !r[0].point) return 1
  return (r[0].point - r[1].point) / r[0].point
}

function report(sentence) {
  const r = score(sentence)
  console.log(`\n"${sentence}"\n`)
  if (!r.length) {
    console.log('  no skill shares vocabulary with that sentence')
    return
  }
  for (const { name, point } of r.slice(0, 5)) console.log(`  ${String(point).padStart(6)}  ${name}`)
  if (r.length > 1) {
    const m = relativeMargin(r)
    console.log(`\n  margin between 1st and 2nd: ${(m * 100).toFixed(0)}%${m < MIN_MARGIN ? '  — not distinguishable' : ''}`)
  }
}

const args = process.argv.slice(2)

// A well-written adapter splits: it yields the generic sentence to the
// procedure it adapts and wins its own. Checking with a single sentence is not
// enough: a mute adapter would pass the good half of the test and still be
// useless.
if (args[0] === '--adaptador' || args[0] === '--adapter') {
  const [, adapter, kernel, generic, own] = args
  if (!adapter || !kernel || !generic || !own) {
    console.error('usage: probe.mjs --adaptador <skill> <kernel-skill> "generic sentence" "sentence with proper names"')
    process.exit(2)
  }
  const wins = (sentence) => score(sentence)[0]?.name || '(none)'
  const g = wins(generic)
  const pr = wins(own)
  const good = g === kernel && pr === adapter

  console.log(`\n  generic   "${generic}"`)
  console.log(`            wins ${g}${g === kernel ? '' : `  — should win ${kernel}`}`)
  console.log(`\n  own       "${own}"`)
  console.log(`            wins ${pr}${pr === adapter ? '' : `  — should win ${adapter}`}`)
  console.log(good
    ? `\n  ${adapter} splits well with ${kernel}\n`
    : `\n  ${adapter} does NOT split with ${kernel}: outside its project the wrong one wins\n`)
  process.exit(good ? 0 : 1)
}

if (args[0] === '--casos' || args[0] === '--cases') {
  const file = args[1] || join(dirname(fileURLToPath(import.meta.url)), '..', 'casos', 'activacion.tsv')
  if (!existsSync(file)) {
    console.error(`the cases file does not exist: ${file}`)
    process.exit(2)
  }
  let total = 0, failures = 0, narrow = 0
  const lines = readFileSync(file, 'utf8').split('\n')
  for (const [i, line] of lines.entries()) {
    if (!line.trim() || line.startsWith('#')) continue
    const [expected, ...rest] = line.split('\t')
    const sentence = rest.join(' ').trim()
    // A tab turned into spaces is the natural mistake when editing this by
    // hand, and skipping it silently leaves a cases file that tests nothing
    // and still comes out green.
    if (!sentence) {
      console.error(`${file}:${i + 1} no tab between the skill and the sentence`)
      process.exit(2)
    }
    total++
    const r = score(sentence)
    const rank = r.findIndex(x => x.name === expected) + 1
    const margin = relativeMargin(r)

    if (rank !== 1) {
      failures++
      console.log(`FAIL   expected ${expected}, ${r[0]?.name || '(none)'} wins${rank ? ` — ${expected} is in position ${rank}` : ` — ${expected} does not score`}`)
      console.log(`       "${sentence}"`)
    } else if (margin < MIN_MARGIN) {
      narrow++
      console.log(`CLOSE  ${expected} wins by ${(margin * 100).toFixed(0)}% over ${r[1].name} — not distinguishable`)
      console.log(`       "${sentence}"`)
    }
  }
  if (!total) {
    console.error(`${file} has not a single case`)
    process.exit(2)
  }
  console.log(`\n${total} cases · ${failures} fail · ${narrow} win without being distinguishable`)
  process.exit(failures ? 1 : 0)
}

if (!args.length) {
  console.error('usage: probe.mjs "sentence"   |   probe.mjs --cases [file]')
  process.exit(2)
}

report(args.join(' '))
