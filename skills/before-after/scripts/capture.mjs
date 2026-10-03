#!/usr/bin/env node
// Captures the same pages in two versions (the published one and the new one)
// to build the before and after.
//
//   node capture.mjs --base <url> --head <url> --paths /,/ficha \
//     --widths 1440,820,390 --out <folder> [--cookie name=value] [--wait 3000] \
//     [--hide '<css selectors>']
//
// Leaves <folder>/before/<page>-<width>.png and <folder>/after/<page>-<width>.png.
// Requires `npm i playwright-core` in the cwd, like visual-test.
import { existsSync, mkdirSync } from 'node:fs'
import { join } from 'node:path'
import { chromium } from 'playwright-core'

const args = Object.fromEntries(
  process.argv.slice(2).reduce((pairs, arg, i, all) => {
    if (arg.startsWith('--')) pairs.push([arg.slice(2), all[i + 1]])
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

const slug = (path) =>
  path.replace(/^\/+|\/+$/g, '').replace(/[^a-z0-9]+/gi, '-').toLowerCase() || 'home'

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
  await page.goto(url, { waitUntil: 'networkidle', timeout: 240000 })
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
  const height = await page.evaluate(() => document.documentElement.scrollHeight)
  // A full-page capture resizes the window, and charts that redraw on resize
  // restart their animation: the shot catches them empty. It is enlarged
  // first, then it waits, and only then does it fire.
  await page.setViewportSize({ width, height })
  await page.waitForTimeout(wait)
  await page.screenshot({ path: file, fullPage: true })
  await ctx.close()
  return height
}

const browser = await launch()
try {
  for (const side of ['before', 'after']) {
    mkdirSync(join(args.out, side), { recursive: true })
    const base = side === 'before' ? args.base : args.head
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
