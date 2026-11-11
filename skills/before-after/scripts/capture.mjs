#!/usr/bin/env node
// Captures the same pages in two versions (the published one and the new one)
// to build the before and after.
//
//   node capture.mjs --base <url> --head <url> --paths /,/ficha \
//     --widths 1440,820,390 --out <folder> [--cookie name=value] [--wait 3000] \
//     [--hide '<css selectors>'] [--selector '<css selector>'] [--repeat] [--hide-fixed]
//
// Leaves <folder>/before/<page>-<width>.png and <folder>/after/<page>-<width>.png.
// --repeat captures the published version once more into <folder>/noise/: what
// differs between two captures of the same version (live data, clocks) is not
// a change, and compose.py leaves it unmarked. --selector captures only the
// first element that matches, in both versions: a component or a section
// instead of the whole page. Fixed layers (consent notices, bottom bars, chat
// bubbles) are hidden when capturing an element, since they would cover it;
// --hide-fixed hides them on whole pages too.
// Requires `npm i playwright-core` in the cwd, like visual-test.
import { existsSync, mkdirSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { chromium } from 'playwright-core'

const FLAGS = new Set(['repeat', 'hide-fixed'])
const args = Object.fromEntries(
  process.argv.slice(2).reduce((pairs, arg, i, all) => {
    if (!arg.startsWith('--')) return pairs
    const name = arg.slice(2)
    pairs.push([name, FLAGS.has(name) ? true : all[i + 1]])
    return pairs
  }, []),
)

for (const required of ['base', 'head', 'paths', 'out']) {
  if (!args[required]) {
    console.error(`missing --${required}`)
    process.exit(2)
  }
}

const widths = (args.widths || '1440,820,390').split(',').map(Number)
const paths = args.paths.split(',')
const wait = Number(args.wait || 3000)
const CHROME =
  process.env.CHROME_BIN ||
  ['/usr/bin/google-chrome', '/usr/bin/chromium', '/usr/bin/chromium-browser'].find(
    (p) => existsSync(p),
  )

// With a development server, the system Chrome may never get to paint (a view
// transition that never ends). The browser Playwright ships does not have
// that, so it goes first if installed.
async function launch() {
  try {
    return await chromium.launch()
  } catch {
    if (!CHROME) throw new Error('no browser: install one or set CHROME_BIN')
    return chromium.launch({ executablePath: CHROME, args: ['--no-sandbox'] })
  }
}

// The query goes into a short fingerprint: two views of the same page keep
// different files, and the names stay readable.
const fingerprint = (text) => {
  let hash = 2166136261
  for (const char of text) hash = Math.imul(hash ^ char.charCodeAt(0), 16777619) >>> 0
  return hash.toString(36).slice(0, 5)
}
const slug = (path) => {
  const [route, query] = path.split('?')
  const base =
    route.replace(/^\/+|\/+$/g, '').replace(/[^a-z0-9]+/gi, '-').toLowerCase() || 'home'
  return query ? `${base}-${fingerprint(query)}` : base
}

async function capture(browser, url, width, file) {
  const mobile = width < 600
  const ctx = await browser.newContext({
    viewport: { width, height: mobile ? 844 : width < 1000 ? 1180 : 900 },
    deviceScaleFactor: width < 1000 ? 2 : 1,
    isMobile: mobile,
    hasTouch: mobile,
  })
  if (args.cookie) {
    const [name, ...value] = args.cookie.split('=')
    await ctx.addCookies([{ name, value: value.join('='), url }])
  }
  const page = await ctx.newPage()
  await page.goto(url, { waitUntil: 'load', timeout: 240000 })
  // A dev server keeps its hot-reload socket open, so the network never goes
  // idle: wait for it briefly and carry on when it does not come.
  await page.waitForLoadState('networkidle', { timeout: 10000 }).catch(() => {})
  // Cookie notices, chat bubbles and other floating layers cover the page in
  // every chunk; each site stores consent its own way, so they are hidden by
  // selector instead of trying to accept them.
  if (args.hide) {
    await page.addStyleTag({ content: `${args.hide} { display: none !important }` })
  }
  // Scrolling through wakes whatever loads on entering the viewport.
  await page.evaluate(async () => {
    for (let y = 0; y < document.documentElement.scrollHeight; y += 600) {
      scrollTo(0, y)
      await new Promise((r) => setTimeout(r, 120))
    }
    scrollTo(0, 0)
  })
  if (args.selector || args['hide-fixed']) {
    await page.evaluate(() => {
      for (const node of document.querySelectorAll('body *')) {
        if (getComputedStyle(node).position === 'fixed') node.style.visibility = 'hidden'
      }
    })
  }
  if (args.selector) {
    const element = page.locator(args.selector).first()
    if ((await element.count()) === 0) {
      throw new Error(`${url}: nothing matches --selector ${args.selector}`)
    }
    await element.scrollIntoViewIfNeeded()
    await page.waitForTimeout(wait)
    // What the element paints, children that stick out of its box included:
    // a full-bleed map inside a padded section would otherwise be cut.
    const clip = await element.evaluate((node) => {
      let [left, top, right, bottom] = [Infinity, Infinity, -Infinity, -Infinity]
      for (const part of [node, ...node.querySelectorAll('*')]) {
        const box = part.getBoundingClientRect()
        if (!box.width || !box.height) continue
        left = Math.min(left, box.left)
        top = Math.min(top, box.top)
        right = Math.max(right, box.right)
        bottom = Math.max(bottom, box.bottom)
      }
      const width = document.documentElement.clientWidth
      left = Math.max(0, left)
      right = Math.min(width, right)
      return { x: left + scrollX, y: top + scrollY, width: right - left, height: bottom - top }
    })
    await page.screenshot({ path: file, clip, fullPage: true, animations: 'disabled' })
    await ctx.close()
    return Math.round(clip.height)
  }
  const height = await page.evaluate(() => document.documentElement.scrollHeight)
  // A full-page capture resizes the window, and charts that redraw on resize
  // restart their animation: the shot catches them empty. It is enlarged
  // first, then it waits, and only then does it fire.
  await page.setViewportSize({ width, height })
  await page.waitForTimeout(wait)
  // Frozen animations: a floating mascot or a pulsing dot caught in two
  // different frames would be marked as a change.
  await page.screenshot({ path: file, fullPage: true, animations: 'disabled' })
  await ctx.close()
  return height
}

mkdirSync(args.out, { recursive: true })
writeFileSync(
  join(args.out, 'pages.json'),
  `${JSON.stringify(Object.fromEntries(paths.map((path) => [slug(path), path])), null, 2)}\n`,
)

const browser = await launch()
try {
  const sides = args.repeat ? ['before', 'after', 'noise'] : ['before', 'after']
  for (const side of sides) {
    mkdirSync(join(args.out, side), { recursive: true })
    const base = side === 'after' ? args.head : args.base
    for (const path of paths) {
      for (const width of widths) {
        const file = join(args.out, side, `${slug(path)}-${width}.png`)
        const height = await capture(browser, new URL(path, base).href, width, file)
        console.log(`${side} ${path} ${width}px → ${height}px`)
      }
    }
  }
} finally {
  await browser.close()
}
