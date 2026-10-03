#!/usr/bin/env node
// Checks the descriptions of a skill catalog: that they exist, that they are
// well formed and that they say when to use the skill.
//
//   check-skill-description.mjs <directory> [language]
//
// The description is what decides whether a skill activates. Everything else in
// the system is verified —structure with doctor, the change with the gate, the
// commit language with a hook— and this was the exception: it was taken on
// trust.
//
// It lived inside block 10 of `doctor`, in bash, and so it only reached the
// project's skills. The kernel's —which are in every session and compete most
// for attention— nobody checked. Moving it here is what allows the same yardstick
// to be applied to both catalogs.
//
// Each finding is printed with its severity first: `error` if the skill cannot
// be loaded, `warning` if it loads but will not activate when it should.

import { readFileSync, existsSync, readdirSync, statSync } from 'node:fs'
import { join, basename, dirname } from 'node:path'

const root = process.argv[2]
const language = process.argv[3] || 'es'
if (!root) {
  console.error('usage: check-skill-description.mjs <skills directory> [language]')
  process.exit(2)
}
if (!existsSync(root)) process.exit(0)

// A usage verb is what turns a description into a trigger. Without it the
// skill is described but does not say in which situation it appears, and then
// it exists without ever being reached.
const TRIGGERS = /(?:^|[^\p{L}])(usa|use|[uú]sala|usar|invoca)(?![\p{L}])/iu

const EN = /\b(the|when|this|with|your|after|before|that|from|which)\b/gi
const ES = /\b(cuando|para|que|con|desde|antes|después|del|las|los|una)\b/gi

function descriptionOf(text) {
  // Only the frontmatter: if more is read, the skill body contaminates the
  // check and this never detects anything.
  const lines = text.split('\n')
  if (lines[0].trim() !== '---') return null
  const output = []
  let inside = false
  for (let i = 1; i < lines.length; i++) {
    const l = lines[i]
    if (l.trim() === '---') break
    if (/^description:/.test(l)) {
      inside = true
      output.push(l.replace(/^description:\s*/, ''))
      continue
    }
    if (inside && /^[a-z_-]+:/.test(l)) break
    if (inside) output.push(l)
  }
  return output.join(' ').replace(/\s+/g, ' ').trim()
}

function skillsIn(dir) {
  const output = []
  const visitNode = (d, depth) => {
    if (depth > 3) return
    for (const preamble of readdirSync(d)) {
      const p = join(d, preamble)
      let st
      try {
        st = statSync(p)
      } catch {
        continue // broken link: reported by `doctor --machine`
      }
      if (st.isDirectory()) visitNode(p, depth + 1)
      else if (preamble === 'SKILL.md') output.push(p)
    }
  }
  visitNode(dir, 0)
  return output.sort()
}

// A skill is loaded whole into the context every time it is used. Above this
// size, what is in excess is almost always the why of each rule, which belongs
// in references/. Measured on 2026-09-28: six skills shortened this way took
// between 45 and 58 % less and answered the same. See /skill-creator.
const MAX_WORDS = 1000

// Those that already exceeded the cap when the rule came in, with their size
// at the time. The list only shrinks: one that grows, or that already fits and
// is still listed, is a finding. Optional file at the catalog root:
// `<name> <words>`.
const inherited = new Map()
const inheritedFile = join(root, '.oversized')
if (existsSync(inheritedFile)) {
  for (const l of readFileSync(inheritedFile, 'utf8').split('\n')) {
    const m = l.replace(/#.*/, '').trim().match(/^(\S+)\s+(\d+)$/)
    if (m) inherited.set(m[1], Number(m[2]))
  }
}
const words = (t) => (t.trim() ? t.trim().split(/\s+/).length : 0)

const findings = []

for (const filePath of skillsIn(root)) {
  const name = basename(dirname(filePath))
  const text = readFileSync(filePath, 'utf8')

  if (text.split('\n')[0].trim() !== '---') {
    findings.push(`error skill without frontmatter: ${name}`)
    continue
  }
  // Without the closing line the frontmatter is not valid YAML and the agent
  // loads the whole skill as body, or does not load it.
  if ((text.match(/^---$/gm) || []).length < 2) {
    findings.push(`error skill with unclosed frontmatter: ${name}`)
    continue
  }
  if (!/^name:/m.test(text)) findings.push(`error skill without 'name' in the frontmatter: ${name}`)
  if (!/^description:/m.test(text)) {
    findings.push(`error skill without 'description' in the frontmatter: ${name}`)
    continue
  }
  if (!new RegExp(`^name: *${name}$`, 'm').test(text)) {
    findings.push(`warning skill '${name}': the frontmatter 'name' does not match the directory`)
  }

  const n = words(text)
  if (inherited.has(name)) {
    if (n > inherited.get(name)) {
      findings.push(`warning skill '${name}': has grown to ${n} words (it had ${inherited.get(name)} and already exceeded ${MAX_WORDS}); move the why to references/`)
    } else if (n <= MAX_WORDS) {
      findings.push(`warning skill '${name}': now fits in ${MAX_WORDS} words (${n}); remove it from .oversized`)
    }
  } else if (n > MAX_WORDS) {
    findings.push(`warning skill '${name}': ${n} words, the maximum is ${MAX_WORDS}; leave the steps in SKILL.md and move the why to references/ (see /skill-creator)`)
  }

  const desc = descriptionOf(text) || ''
  if (!TRIGGERS.test(desc)) {
    findings.push(`warning skill '${name}': the description does not say when to use it — it will not activate on its own`)
  }

  // The description decides activation, so it has to be in the language in which
  // the work is requested. A mix activates worse exactly where it hurts most.
  if (language === 'es') {
    const en = (desc.match(EN) || []).length
    const es = (desc.match(ES) || []).length
    if (en > es) {
      findings.push(`warning skill '${name}': the description seems to be in English and the catalog declares Spanish`)
    }
  }
}

for (const h of findings) console.log(h)
process.exit(0)
