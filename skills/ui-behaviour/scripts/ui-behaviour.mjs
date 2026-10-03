#!/usr/bin/env node
// ui-behaviour — check that controls do something when pressed.
//
//   node ui-behaviour.mjs sweep <url> [--mobile]
//   node ui-behaviour.mjs probe <url> "<button text>" [--scope <sel>] [--mobile]
//
// sweep: quick pass over all the controls, lists the suspects.
// probe: reloads, narrows to the component and presses a single one twice.
import { chromium } from 'playwright-core'


const CHROME =
  process.env.CHROME_BIN ||
  ['/usr/bin/google-chrome', '/usr/bin/chromium', '/usr/bin/chromium-browser'].find(
    (p) => {
      try { return require('node:fs').existsSync(p) } catch { return false }
    },
  ) ||
  '/usr/bin/google-chrome'

const MOBILE = { viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true }
const DESKTOP = { viewport: { width: 1280, height: 900 }, deviceScaleFactor: 1 }

const [mode, ...rest] = process.argv.slice(2)
const mobile = rest.includes('--mobile')
const url = rest[0]

// The fingerprint: what the user would see change. Not the whole HTML, which
// changes for reasons that do not matter.
const FINGERPRINT = () => {
  const t = (sel, n = 12) =>
    [...document.querySelectorAll(sel)].slice(0, n).map((e) => e.textContent.trim()).join('|')
  return {
    rows: [...document.querySelectorAll('table')].map((x) => x.querySelectorAll('tbody tr').length).join(','),
    firstRow: t('table tbody tr:first-child td', 6),
    headers: t('table thead th', 14),
    active: [...document.querySelectorAll('.active, [aria-selected="true"], [aria-pressed="true"], [aria-current]')]
      .slice(0, 14)
      .map((e) => e.textContent.trim().slice(0, 22))
      .join('|'),
    counters: t('[class*="pagination"], [class*="count"], [class*="footer"] span', 6),
    cards: document.querySelectorAll('li, [class*="chip"], [class*="card"]').length,
    dialogs: document.querySelectorAll('dialog[open], [role="dialog"]').length,
    url: location.href,
  }
}

async function open(browser) {
  const ctx = await browser.newContext(mobile ? MOBILE : DESKTOP)
  const page = await ctx.newPage()
  await page.goto(url, { waitUntil: 'networkidle', timeout: 40000 }).catch(() => {})
  for (let i = 0; i < 45; i++) {
    await page.evaluate(() => window.scrollBy(0, 450))
    await page.waitForTimeout(120)
  }
  await page.waitForTimeout(2200)
  return page
}

const browser = await chromium.launch({ executablePath: CHROME, args: ['--no-sandbox'] })

if (mode === 'sweep') {
  const page = await open(browser)
  const errs = []
  page.on('pageerror', (e) => errs.push(String(e).slice(0, 90)))
  const n = await page.$$eval('main button, main a[href]', (e) => e.length)
  const suspects = []
  let tested = 0
  for (let i = 0; i < n; i++) {
    const meta = await page.evaluate((idx) => {
      const e = [...document.querySelectorAll('main button, main a[href]')][idx]
      if (!e) return null
      const r = e.getBoundingClientRect()
      return {
        txt: (e.textContent || '').trim().slice(0, 30) || e.getAttribute('aria-label') || '(no text)',
        ok: r.width > 0 && r.height > 0 && !e.disabled && e.tagName === 'BUTTON',
      }
    }, i)
    if (!meta || !meta.ok) continue
    const before = await page.evaluate(FINGERPRINT)
    const el = (await page.$$('main button, main a[href]'))[i]
    await el.scrollIntoViewIfNeeded().catch(() => {})
    await el.click({ timeout: 2500 }).catch(() => {})
    await page.waitForTimeout(700)
    const after = await page.evaluate(FINGERPRINT)
    tested++
    const changed = Object.keys(before).some((k) => before[k] !== after[k])
    if (!changed) suspects.push(meta.txt)
  }
  console.log(`${tested} controls pressed · ${suspects.length} with no apparent effect`)
  suspects.forEach((s) => console.log(`  ? ${s}`))
  console.log(
    suspects.length
      ? '\nThese are SUSPECTS, not failures. Run each through `probe` before reporting it:\n' +
          'the pass chains clicks, so many land on an already active state.'
      : '\nAll of them produce some change.',
  )
  console.log('console errors:', errs.length ? [...new Set(errs)] : 'none')
} else if (mode === 'probe') {
  const text = rest[1]
  const si = rest.indexOf('--scope')
  const scope = si >= 0 ? rest[si + 1] : 'main'
  const page = await open(browser)
  const sel = `${scope} button:has-text("${text}")`
  const howMany = await page.$$eval(sel, (e) => e.length).catch(() => 0)
  if (!howMany) {
    console.log(`not found: ${sel}`)
} else {
    if (howMany > 1)
      console.log(`⚠  ${howMany} controls match ${sel} — narrow down with --scope`)
    const el = await page.$(sel)
    const diff = (a, b) =>
      Object.keys(a)
        .filter((k) => a[k] !== b[k])
        .map((k) => `${k}: ${String(a[k]).slice(0, 44)} -> ${String(b[k]).slice(0, 44)}`)
    const h0 = await page.evaluate(FINGERPRINT)
    await el.scrollIntoViewIfNeeded().catch(() => {})
    await el.click({ timeout: 3000 }).catch(() => {})
    await page.waitForTimeout(900)
    const h1 = await page.evaluate(FINGERPRINT)
    const d1 = diff(h0, h1)
    console.log('1st click:', d1.length ? '' : 'no changes')
    d1.forEach((l) => console.log('   ' + l))
    await el.click({ timeout: 3000 }).catch(() => {})
    await page.waitForTimeout(900)
    const h2 = await page.evaluate(FINGERPRINT)
    const d2 = diff(h1, h2)
    console.log('2nd click:', d2.length ? '' : 'no changes')
    d2.forEach((l) => console.log('   ' + l))
    console.log(
      '\nIf the 1st click changes nothing but the 2nd does, the control works: the\n' +
        'first state matched the one it already had by default.',
    )
  }
} else if (mode === 'keyboard') {
// Tab through the interface: what does not receive focus does not exist for
// someone who does not use a mouse. And an invisible focus ring is the same as
// having none.
const page = await open(browser)
await page.evaluate(() => window.scrollTo(0, 0))
await page.waitForTimeout(400)

const operable = await page.$$eval(
  'main button, main a[href], main input, main select, main textarea, main [tabindex]',
  (els) =>
    els
      .filter((e) => {
        const r = e.getBoundingClientRect()
        return r.width > 0 && r.height > 0 && !e.disabled && e.tabIndex !== -1
      })
      .map((e) => ({
        txt: (e.textContent || '').trim().slice(0, 26) || e.getAttribute('aria-label') || e.tagName,
        y: Math.round(e.getBoundingClientRect().top + window.scrollY),
      })),
)

// Real walk with the Tab key
const visited = []
await page.evaluate(() => document.body.focus())
for (let i = 0; i < 220; i++) {
  await page.keyboard.press('Tab')
  const f = await page.evaluate(() => {
    const e = document.activeElement
    if (!e || e === document.body) return null
    const c = getComputedStyle(e)
    const r = e.getBoundingClientRect()
    return {
      txt: (e.textContent || '').trim().slice(0, 26) || e.getAttribute('aria-label') || e.tagName,
      inMain: !!e.closest('main'),
      y: Math.round(r.top + window.scrollY),
      ring:
        c.outlineStyle !== 'none' && parseFloat(c.outlineWidth) > 0
          ? 'outline'
          : c.boxShadow !== 'none'
            ? 'shadow'
            : 'none',
    }
  })
  if (!f) break
  if (f.inMain) visited.push(f)
}

const withoutRing = visited.filter((v) => v.ring === 'none')
let jumps = 0
for (let i = 1; i < visited.length; i++)
  if (visited[i].y < visited[i - 1].y - 120) jumps++

console.log(`operable in main: ${operable.length}`)
console.log(`reached with Tab: ${visited.length}`)
console.log(`without a visible focus ring: ${withoutRing.length}`)
console.log(`backward jumps in the order: ${jumps}`)
if (operable.length > visited.length)
  console.log(
    `\n⚠  ${operable.length - visited.length} operable controls were not reached by tabbing.`,
  )
withoutRing.slice(0, 10).forEach((v) => console.log(`  no ring: ${v.txt}`))
console.log(
  '\nNote: controls inside a scrolling container need\n' +
    'tabindex="0" on the container, or the region cannot be walked by keyboard.',
)
} else {
  console.log('modes: sweep <url> | probe <url> "<text>" [--scope <sel>] | keyboard <url>')
  process.exit(1)
}

await browser.close()
