#!/usr/bin/env node
// Markers of generated UI, measured on the rendered page.
// Usage:
//   node ui-tells.mjs check <url> [url...]   # counts the markers
//   node ui-tells.mjs detail <url>           # shows each case with its text
// (revisar / detalle still work)
//
// Requires: google-chrome installed and `npm i playwright-core` in the cwd.
import { existsSync } from 'node:fs'
import { chromium } from 'playwright-core'

const CHROME =
  process.env.CHROME_BIN ||
  [
    '/usr/bin/google-chrome',
    '/usr/bin/chromium',
    '/usr/bin/chromium-browser',
  ].find((p) => existsSync(p)) ||
  '/usr/bin/google-chrome'

const DESKTOP = { viewport: { width: 1440, height: 900 }, deviceScaleFactor: 1 }

// The scored ones are objective failures: the text either fits or it does
// not, the navigation is either 80px tall or it is not. The merely reported
// ones depend on the designer's judgement, and a regex cannot decide for them.
const SCORED = ['emDash', 'heroOverflow', 'tallNav', 'splitCta', 'fixedHeight']
const REPORTED = [
  'equalThree',
  'eyebrows',
  'midDot',
  'numberedEyebrow',
  'fakeChrome',
  'scrollCue',
  'heroVersion',
  'genericName',
  'roundFigure',
  'fillerVerb',
]

const LABELS = {
  emDash: 'Em or en dash (— or –) in visible text',
  heroOverflow: 'The headline or call to action do not fit on the first screen',
  tallNav: 'Navigation taller than 80px or split over two lines',
  splitCta: 'Button label split over two lines',
  fixedHeight: 'Height 100vh instead of 100dvh',
  equalThree: 'Grid of three equal columns',
  eyebrows: 'Small-caps eyebrows above the cap',
  midDot: 'Lines with more than one middle dot (·)',
  numberedEyebrow: 'Numbered eyebrow (001 ·, 00 / INDEX)',
  fakeChrome: 'Fake window drawn with divs',
  scrollCue: 'Written "scroll" hint',
  heroVersion: 'Version or beta label on the first screen',
  genericName: 'Placeholder name or brand (Acme, John Doe, Lorem)',
  roundFigure: 'Falsely round figure (99.9%, 50%, 10,000)',
  fillerVerb: 'Brochure verb (impulsar, potenciar, unleash, seamless)',
}

const MEASURE = `(() => {
  const visible = (e) => {
    const s = getComputedStyle(e)
    if (s.display === 'none' || s.visibility === 'hidden' || +s.opacity === 0) return false
    const r = e.getBoundingClientRect()
    return r.width > 0 && r.height > 0
  }
  const sheets = () => {
    let css = ''
    for (const sheet of document.styleSheets) {
      try {
        for (const r of sheet.cssRules) css += r.cssText
      } catch (e) {}
    }
    return css
  }
  const text = document.body.innerText
  const lines = text.split('\\n').map((l) => l.trim()).filter(Boolean)
  const all = [...document.querySelectorAll('body *')].filter(visible)
  const cssText = sheets()
  const viewportHeight = innerHeight
  const cases = {}
  const note = (key, sample) => {
    cases[key] = cases[key] || []
    if (cases[key].length < 12) cases[key].push(String(sample).slice(0, 110))
  }

  for (const l of lines) if (/[—–]/.test(l)) note('emDash', l)

  const h1 = document.querySelector('h1')
  if (h1) {
    const r = h1.getBoundingClientRect()
    if (r.bottom > viewportHeight) note('heroOverflow', 'the h1 ends at ' + Math.round(r.bottom) + 'px')
    const cta = [...document.querySelectorAll('a,button')].filter(visible).find((e) => {
      const c = e.getBoundingClientRect()
      return c.top > r.top && (e.innerText || '').trim().length > 1
    })
    if (cta && cta.getBoundingClientRect().bottom > viewportHeight) {
      note('heroOverflow', 'the first call to action falls outside: ' + cta.innerText.trim())
    }
  }

  const nav = document.querySelector('header nav, nav, header')
  if (nav && visible(nav)) {
    const r = nav.getBoundingClientRect()
    if (r.height > 80) note('tallNav', Math.round(r.height) + 'px tall')
    // Two links are on different rows only if more than half a link height
    // separates them. A few pixels is alignment, not a line break.
    const links = [...nav.querySelectorAll('a')].filter(visible)
    const boxes = links.map((a) => a.getBoundingClientRect())
    const slack = Math.max(12, Math.max(...boxes.map((c) => c.height), 0) / 2)
    const rows = []
    for (const c of boxes.sort((a, b) => a.top - b.top)) {
      if (!rows.length || c.top - rows[rows.length - 1] > slack) rows.push(c.top)
    }
    if (links.length > 2 && rows.length > 1) {
      note('tallNav', 'the links span ' + rows.length + ' rows')
    }
  }

  // Counting the rectangles of a range over the text itself is the only thing
  // that tells a split label from one with a lot of vertical padding.
  const textRows = (e) => {
    let rows = 0
    for (const n of e.childNodes) {
      if (n.nodeType !== 3 || !n.textContent.trim()) continue
      const r = document.createRange()
      r.selectNodeContents(n)
      const boxes = [...r.getClientRects()].filter((c) => c.width > 1 && c.height > 1)
      const tops = new Set(boxes.map((c) => Math.round(c.top / 4)))
      rows = Math.max(rows, tops.size)
    }
    return rows
  }
  for (const e of [...document.querySelectorAll('a,button')].filter(visible)) {
    const t = (e.innerText || '').trim()
    if (!t || t.length > 40 || t.includes('\\n')) continue
    if (textRows(e) > 1) note('splitCta', t)
  }

  // 100vh does not shrink when the mobile browser hides the address bar, so
  // the content jumps. 100dvh does. calc() over 100vh counts the same: it
  // carries the same bug.
  for (const chunk of cssText.match(/[^{}]+\\{[^{}]*100vh[^{}]*\\}/g) || []) {
    note('fixedHeight', chunk.replace(/\\s+/g, ' ').slice(0, 100))
  }

  for (const e of all) {
    const s = getComputedStyle(e)
    if (s.display !== 'grid') continue
    const cols = s.gridTemplateColumns.split(' ').filter(Boolean)
    if (cols.length !== 3) continue
    if (new Set(cols.map((c) => Math.round(parseFloat(c)))).size !== 1) continue
    if (e.children.length !== 3) continue
    note('equalThree', (e.innerText || '').replace(/\\s+/g, ' ').slice(0, 90))
  }

  const sections = Math.max(1, document.querySelectorAll('section').length)
  const cap = Math.ceil(sections / 3)
  const eyebrowEls = all.filter((e) => {
    if (e.children.length) return false
    const t = (e.textContent || '').trim()
    if (t.length < 2 || t.length > 42) return false
    const s = getComputedStyle(e)
    const upper = s.textTransform === 'uppercase' || (t === t.toUpperCase() && /[A-ZÁÉÍÓÚÑ]/.test(t))
    return upper && parseFloat(s.letterSpacing) > 0.8
  })
  for (const c of eyebrowEls) {
    const t = c.textContent.trim()
    if (/^[0-9]{2,3}\\s*[\\/·.-]|^[0-9]{2,3}\\s+[A-Za-zÁ-Úá-ú]/.test(t)) note('numberedEyebrow', t)
  }
  if (eyebrowEls.length > cap) {
    note('eyebrows', eyebrowEls.length + ' eyebrows for ' + sections + ' sections (cap ' + cap + ')')
  }

  for (const l of lines) if ((l.match(/·/g) || []).length > 1) note('midDot', l)

  for (const e of all) {
    const kids = [...e.children].filter(visible)
    if (kids.length < 3) continue
    const dots = kids.filter((h) => {
      const r = h.getBoundingClientRect()
      const s = getComputedStyle(h)
      return r.width < 18 && r.height < 18 && Math.abs(r.width - r.height) < 4 &&
        parseFloat(s.borderRadius) >= r.width / 2 - 1 && !(h.innerText || '').trim()
    })
    if (dots.length < 3) continue
    const y = new Set(dots.map((p) => Math.round(p.getBoundingClientRect().top)))
    if (y.size !== 1) continue
    // A window frame around a real screenshot is legitimate. The tell is
    // drawing the whole interface with divs, with no image inside.
    const frame = e.closest('figure, div, section') || e
    const root = frame.parentElement || frame
    if (root.querySelector('img, canvas, video, picture, svg image')) continue
    note('fakeChrome', (root.innerText || '').replace(/\\s+/g, ' ').slice(0, 80) || 'window drawn with divs')
  }

  for (const l of lines) {
    if (/^(scroll|desliza|↓\\s*scroll|scroll to explore|scroll para)\\b/i.test(l) && l.length < 30) {
      note('scrollCue', l)
    }
  }

  for (const e of all) {
    if (e.getBoundingClientRect().top > viewportHeight) continue
    const t = (e.textContent || '').trim()
    if (e.children.length || t.length > 26) continue
    if (/\\b(beta|alpha|early access|invite[- ]only|v\\d+(\\.\\d+)+|rc\\.\\d+)\\b/i.test(t)) {
      note('heroVersion', t)
    }
  }

  const generics = /\\b(acme|john doe|jane doe|jack su|sarah chan|lorem ipsum|nexus|smartflow|cloudly|example\\.com|foo ?bar)\\b/i
  for (const l of lines) if (generics.test(l)) note('genericName', l)

  for (const l of lines) {
    if (/(^|\\s)(99[.,]9{1,2}\\s?%|100\\s?%|50\\s?%|10\\.000|1\\.000\\.000|1234567)(\\s|$)/.test(l) && l.length < 60) {
      note('roundFigure', l)
    }
  }

  const filler = /\\b(impulsar|potenciar|revolucionar|desbloquear|empoderar|sin fisuras|de nueva generaci[oó]n|elevate|unleash|seamless|next[- ]gen|revolutioniz\\w*|supercharge|empower)\\b/i
  for (const l of lines) if (filler.test(l)) note('fillerVerb', l)

  return { cases, sections, lines: lines.length }
})()`

async function measure(url) {
  const browser = await chromium.launch({
    executablePath: CHROME,
    args: ['--no-sandbox'],
  })
  try {
    const ctx = await browser.newContext(DESKTOP)
    const page = await ctx.newPage()
    await page.goto(url, { waitUntil: 'load', timeout: 45000 })
    // A dev server keeps its hot-reload socket open, so the network never goes
    // idle: wait for it briefly and carry on when it does not come.
    await page.waitForLoadState('networkidle', { timeout: 10000 }).catch(() => {})
    await page.waitForTimeout(900)
    return await page.evaluate(MEASURE)
  } finally {
    await browser.close()
  }
}

function row(key, n) {
  const marker = n === 0 ? '   ' : SCORED.includes(key) ? '🔴 ' : '⚠️  '
  return `${marker}${String(n).padStart(3)}  ${LABELS[key]}`
}

function report(url, r, detail) {
  const load = SCORED.reduce((s, k) => s + (r.cases[k]?.length || 0), 0)
  const warnings = REPORTED.reduce((s, k) => s + (r.cases[k]?.length || 0), 0)

  console.log(`\n${url}`)
  console.log(`${r.lines} lines of text · ${r.sections} sections\n`)
  console.log('  objective failures')
  for (const k of SCORED) console.log('  ' + row(k, r.cases[k]?.length || 0))
  console.log('\n  hints, your call')
  for (const k of REPORTED) console.log('  ' + row(k, r.cases[k]?.length || 0))

  if (detail) {
    console.log('')
    for (const k of [...SCORED, ...REPORTED]) {
      const cases = r.cases[k]
      if (!cases?.length) continue
      console.log(`\n  ${LABELS[k]}`)
      for (const c of cases) console.log('    · ' + c)
    }
  }

  console.log(
    `\nload ${load} · ${warnings} hints — ` +
      (load === 0
        ? warnings === 0
          ? 'clean'
          : 'no objective failures, look at the hints'
        : 'there are failures to fix'),
  )
  return load
}

const [rawMode, ...urls] = process.argv.slice(2)
const MODE_ALIASES = { check: 'revisar', detail: 'detalle' }
const mode = MODE_ALIASES[rawMode] || rawMode
if (!mode || !urls.length || !['revisar', 'detalle'].includes(mode)) {
  console.log('usage: ui-tells.mjs check <url> [url...]  |  ui-tells.mjs detail <url>')
  process.exit(2)
}

let worst = 0
for (const url of urls) {
  const r = await measure(url)
  worst = Math.max(worst, report(url, r, mode === 'detalle'))
}
console.log(
  '\nObjective failures get fixed. Hints are judgement: a grid of three\n' +
    'columns may be exactly what the content calls for.',
)
process.exit(worst > 0 ? 1 : 0)
