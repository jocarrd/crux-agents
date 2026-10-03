#!/usr/bin/env node
// Headless visual testing with the system Chrome (via playwright-core).
// Usage:
//   node visual.mjs shot   <url> <out.png> [--desktop] [--scroll N]
//   node visual.mjs audit  <url> [url...]          # horizontal scroll + culprits
//   node visual.mjs bisect <url> [--threshold N]   # locates the element that overflows
//   node visual.mjs checks <url>                   # mobile design/usability signals
//   node visual.mjs a11y   <url> [--desktop]       # WCAG audit with axe-core (CDN)
//
// Requires: google-chrome installed and `npm i playwright-core` in the cwd.
// The a11y mode injects axe-core from a CDN (needs network).
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

const MOBILE = {
  viewport: { width: 390, height: 844 },
  deviceScaleFactor: 2,
  isMobile: true,
  hasTouch: true,
  userAgent:
    'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
}
const DESKTOP = { viewport: { width: 1280, height: 900 }, deviceScaleFactor: 1 }

const [mode, ...rest] = process.argv.slice(2)

async function withPage(ctxOpts, fn) {
  const browser = await chromium.launch({
    executablePath: CHROME,
    args: ['--no-sandbox'],
  })
  const ctx = await browser.newContext(ctxOpts)
  const page = await ctx.newPage()
  try {
    return await fn(page)
  } finally {
    await browser.close()
  }
}

async function load(page, url) {
  // Dev (turbopack) compiles on the fly and sometimes a dynamic chunk fails on
  // the 1st attempt: warm up twice.
  for (let i = 0; i < 2; i++) {
    await page
      .goto(url, { waitUntil: 'networkidle', timeout: 35000 })
      .catch(() => {})
    await page.waitForTimeout(i ? 2000 : 800)
  }
}

// --- walk like a person would ----------------------------------------------
// Entrance animations and islands that hydrate late only show if you scroll
// down with pauses. A single jump measures the previous state.
async function traverse(page, steps = 60, jump = 500, wait = 150) {
  for (let i = 0; i < steps; i++) {
    await page.evaluate((y) => window.scrollBy(0, y), jump)
    await page.waitForTimeout(wait)
  }
  await page.waitForTimeout(2500)
}

function contrastRatio(a, b) {
  const channel = (c) => {
    const m = c.match(/color\(srgb\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)/)
    if (m) return [+m[1], +m[2], +m[3]]
    const n = c.match(/[\d.]+/g)
    return n ? n.slice(0, 3).map((x) => +x / 255) : [0, 0, 0]
  }
  const lum = (c) => {
    const [r, g, bl] = channel(c).map((n) =>
      n <= 0.03928 ? n / 12.92 : ((n + 0.055) / 1.055) ** 2.4,
    )
    return 0.2126 * r + 0.7152 * g + 0.0722 * bl
  }
  const la = lum(a)
  const lb = lum(b)
  return +((Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05)).toFixed(2)
}

if (mode === 'invisible') {
  // An entrance animation that never fires leaves the content at opacity 0
  // forever. Neither the build, the typecheck nor axe sees it.
  const urls = rest.filter((r) => !r.startsWith('--'))
  const desktop = rest.includes('--desktop')
  let bad = 0
  await withPage(desktop ? DESKTOP : MOBILE, async (page) => {
    for (const url of urls) {
      await load(page, url)
      await traverse(page)
      const hidden = await page.evaluate(() => {
        const insideCarousel = (e) => !!e.closest('.swiper, [data-carousel]')
        return [...document.querySelectorAll('main *')]
          .filter((e) => {
            if (insideCarousel(e)) return false
            const c = getComputedStyle(e)
            if (c.visibility === 'hidden' || +c.opacity < 0.95) {
              const r = e.getBoundingClientRect()
              return r.width > 24 && r.height > 12 && (e.textContent || '').trim()
            }
            return false
          })
          .slice(0, 8)
          .map((e) => `${e.tagName}.${(e.className || '').toString().split(' ')[0]}`)
      })
      if (hidden.length) {
        bad++
        console.log(`🔴 ${url} — ${hidden.length} invisible elements`)
        hidden.forEach((o) => console.log(`   ${o}`))
      } else console.log(`✅ ${url} — nothing invisible`)
    }
  })
  if (bad) process.exit(1)
} else if (mode === 'hydration') {
  // A hydration failure makes the framework throw away the server HTML and
  // repaint on the client. It only shows by listening to pageerror while
  // scrolling through.
  const urls = rest.filter((r) => !r.startsWith('--'))
  const desktop = rest.includes('--desktop')
  let bad = 0
  await withPage(desktop ? DESKTOP : MOBILE, async (page) => {
    for (const url of urls) {
      const errs = []
      page.on('pageerror', (e) => errs.push(String(e).slice(0, 120)))
      page.on('console', (m) => {
        if (m.type() === 'error') errs.push('console: ' + m.text().slice(0, 120))
      })
      await load(page, url)
      await traverse(page, 45, 500, 120)
      if (errs.length) {
        bad++
        console.log(`🔴 ${url}`)
        ;[...new Set(errs)].slice(0, 5).forEach((e) => console.log(`   ${e}`))
      } else console.log(`✅ ${url} — no console errors`)
      page.removeAllListeners('pageerror')
      page.removeAllListeners('console')
    }
  })
  if (bad) process.exit(1)
} else if (mode === 'states') {
  // axe measures the idle state. A button can pass at rest and fail on hover
  // or when left active, and nobody sees that.
  const url = rest[0]
  const desktop = !rest.includes('--mobile')
  await withPage(desktop ? DESKTOP : MOBILE, async (page) => {
    await load(page, url)
    await traverse(page, 40, 450, 130)
    const n = await page.$$eval('main button, main a[href]', (e) => e.length)
    const rows = []
    for (let i = 0; i < n; i++) {
      const el = (await page.$$('main button, main a[href]'))[i]
      if (!el) continue
      const meta = await page.evaluate((idx) => {
        const e = [...document.querySelectorAll('main button, main a[href]')][idx]
        const r = e.getBoundingClientRect()
        return {
          txt: (e.textContent || '').trim().slice(0, 28) || e.getAttribute('aria-label') || '(no text)',
          ok: r.width > 0 && r.height > 0 && !e.disabled,
        }
      }, i)
      if (!meta.ok) continue
      const read = () =>
        page.evaluate((idx) => {
          const e = [...document.querySelectorAll('main button, main a[href]')][idx]
          const c = getComputedStyle(e)
          let background = c.backgroundColor
          let node = e
          while (background === 'rgba(0, 0, 0, 0)' && node.parentElement) {
            node = node.parentElement
            background = getComputedStyle(node).backgroundColor
          }
          return { color: c.color, background, cursor: c.cursor }
        }, i)
      await el.scrollIntoViewIfNeeded().catch(() => {})
      await page.mouse.move(2, 2)
      await page.waitForTimeout(450)
      const idle = await read()
      await el.hover({ timeout: 2000 }).catch(() => {})
      await page.waitForTimeout(500)
      const hover = await read()
      rows.push({
        txt: meta.txt,
        idle: contrastRatio(idle.color, idle.background),
        hover: contrastRatio(hover.color, hover.background),
        cursor: hover.cursor,
      })
    }
    const bad = rows.filter((f) => f.idle < 4.5 || f.hover < 4.5)
    console.log(`${rows.length} controls · ${bad.length} below 4.5`)
    bad.forEach((f) =>
      console.log(`🔴 "${f.txt}" idle:${f.idle} hover:${f.hover}`),
    )
    if (!bad.length) console.log('✅ all pass AA at rest and on hover')
    console.log(
      '\nNote: states that only exist on press (active tab, selected chip)',
    )
    console.log('have to be activated and measured again by hand.')
  })
} else if (mode === 'rhythm') {
  // The space between sections and what is left where the background band changes.
  const url = rest[0]
  const desktop = !rest.includes('--mobile')
  await withPage(desktop ? DESKTOP : MOBILE, async (page) => {
    await load(page, url)
    await traverse(page, 30, 600, 100)
    await page.evaluate(() => window.scrollTo(0, 0))
    await page.waitForTimeout(700)
    const rows = await page.evaluate(() => {
      const secs = [...document.querySelectorAll('main section, main > div')]
      return secs.map((s, i) => {
        const c = getComputedStyle(s)
        const r = s.getBoundingClientRect()
        const next = secs[i + 1]
        const header = s.querySelector('h1, h2, h3, header')
        return {
          name: (s.id || (s.className || '').toString().split(' ')[0] || '?').slice(0, 26),
          background: c.backgroundColor,
          padT: Math.round(parseFloat(c.paddingTop)),
          padB: Math.round(parseFloat(c.paddingBottom)),
          gap: next
            ? Math.round(
                next.getBoundingClientRect().top - r.bottom +
                  parseFloat(c.paddingBottom) +
                  parseFloat(getComputedStyle(next).paddingTop),
              )
            : null,
          toHeading: header ? Math.round(header.getBoundingClientRect().top - r.top) : null,
          bgChanges: next ? getComputedStyle(next).backgroundColor !== c.backgroundColor : false,
        }
      })
    })
    console.log('section                     background           padT  padB    gap  to heading')
    rows.forEach((f) =>
      console.log(
        `${f.name.padEnd(27)} ${f.background.padEnd(20)} ${String(f.padT).padStart(4)} ${String(f.padB).padStart(5)} ${String(f.gap ?? '-').padStart(6)} ${String(f.toHeading ?? '-').padStart(11)}` +
          (f.bgChanges && f.padB === 0 ? '  ← the background changes and there is no gap' : ''),
      ),
    )
    const cramped = rows.filter((f) => f.toHeading !== null && f.toHeading < 24 && f.padT < 24)
    if (cramped.length)
      console.log(`\n🔴 ${cramped.length} sections with the heading stuck to the edge`)
  })
} else if (mode === 'shot') {

  const url = rest[0]
  const out = rest[1] || 'shot.png'
  const desktop = rest.includes('--desktop')
  const si = rest.indexOf('--scroll')
  const scroll = si >= 0 ? parseInt(rest[si + 1] || '0', 10) : 0
  await withPage(desktop ? DESKTOP : MOBILE, async (page) => {
    await load(page, url)
    if (scroll) await page.evaluate((y) => window.scrollTo(0, y), scroll)
    await page.waitForTimeout(700)
    await page.screenshot({ path: out })
    console.log('shot', out, desktop ? '(desktop 1280)' : '(mobile 390)')
  })
} else if (mode === 'audit') {
  await withPage(MOBILE, async (page) => {
    for (const url of rest) {
      await load(page, url)
      const r = await page.evaluate(() => {
        const vw = window.innerWidth
        const overflow = document.scrollingElement.scrollWidth - vw
        const culprits = []
        document.querySelectorAll('body *').forEach((el) => {
          const b = el.getBoundingClientRect()
          const cs = getComputedStyle(el)
          if (cs.position === 'absolute' || cs.position === 'fixed') return
          if (b.width > vw + 1) culprits.push({ tag: el.tagName, cls: (el.className || '').toString().slice(0, 70), w: Math.round(b.width) })
        })
        culprits.sort((a, b) => b.w - a.w)
        return { vw, overflow, n: culprits.length, top: culprits.slice(0, 6) }
      })
      const flag = r.overflow > 1 || r.vw > 391 ? '  ⚠ SCROLL HORIZONTAL' : '  ok'
      console.log(`\n=== ${url} ===`)
      console.log(`innerWidth=${r.vw} overflowH=${r.overflow}px${flag}`)
      r.top.forEach((c) => console.log(`  <${c.tag} w=${c.w}> .${c.cls}`))
    }
  })
} else if (mode === 'bisect') {
  const url = rest[0]
  const ti = rest.indexOf('--threshold')
  const thr = ti >= 0 ? parseInt(rest[ti + 1] || '40', 10) : 40
  await withPage(MOBILE, async (page) => {
    await load(page, url)
    const r = await page.evaluate((thr) => {
      const base = document.scrollingElement.scrollWidth
      const hits = []
      for (const el of document.querySelectorAll('body *')) {
        if (getComputedStyle(el).display === 'none') continue
        const prev = el.style.display
        el.style.display = 'none'
        const w = document.scrollingElement.scrollWidth
        el.style.display = prev
        if (base - w > thr)
          hits.push({ tag: el.tagName, cls: (el.className || '').toString().slice(0, 70), drop: base - w, kids: el.childElementCount, txt: el.childElementCount <= 2 ? (el.textContent || '').trim().slice(0, 40) : '' })
      }
      hits.sort((a, b) => b.drop - a.drop || a.kids - b.kids)
      return { base, hits: hits.slice(0, 8) }
    }, thr)
    console.log(`scrollWidth base=${r.base} (leaf kids=0 = real culprit)`)
    r.hits.forEach((h) => console.log(`  -${h.drop}px kids=${h.kids} <${h.tag}> .${h.cls}${h.txt ? '  "' + h.txt + '"' : ''}`))
  })
} else if (mode === 'checks') {
  // Objective design/usability signals on mobile (does not replace the eye).
  await withPage(MOBILE, async (page) => {
    await load(page, rest[0])
    const r = await page.evaluate(() => {
      const vw = window.innerWidth
      const visible = (el) => {
        const b = el.getBoundingClientRect()
        const cs = getComputedStyle(el)
        return (
          b.width > 0 &&
          b.height > 0 &&
          cs.visibility !== 'hidden' &&
          cs.display !== 'none'
        )
      }
      const label = (el) =>
        `<${el.tagName.toLowerCase()}${el.className ? ' .' + el.className.toString().trim().split(/\s+/).slice(0, 2).join('.') : ''}> ${(el.textContent || el.getAttribute('aria-label') || '').trim().slice(0, 30)}`

      // Tap targets: only "button-like" ones count (pill/chip/control with a
      // box: its own background, border or padding). Inline text links (no box)
      // are tapped by tapping the text and are NOT measured by the 44px rule.
      const transparent = (c) => !c || c === 'transparent' || /, 0\)$/.test(c)
      const hasBox = (el, cs) =>
        el.tagName === 'INPUT' ||
        el.tagName === 'SELECT' ||
        parseFloat(cs.borderTopWidth) > 0 ||
        parseFloat(cs.borderBottomWidth) > 0 ||
        !transparent(cs.backgroundColor) ||
        cs.backgroundImage !== 'none'
      const tap = { severe: [], minor: [] }
      document
        .querySelectorAll('a, button, [role="button"], input, select, [onclick]')
        .forEach((el) => {
          if (!visible(el)) return
          const cs = getComputedStyle(el)
          if (cs.display === 'inline') return
          const b = el.getBoundingClientRect()
          const min = Math.min(b.width, b.height)
          if (min >= 40) return
          const entry = `${Math.round(b.width)}x${Math.round(b.height)}  ${label(el)}`
          if (min < 24) {
            // tiny: only a problem if "button-like" (with a box). A text link
            // without background/border is tapped by tapping the text: not counted.
            if (hasBox(el, cs)) tap.severe.push(entry)
          } else {
            tap.minor.push(entry)
          }
        })

      // Text: <10px is almost always a problem; 10-12px is usually an
      // intentional caption/secondary label (to review, not an alarm).
      const tiny = { severe: [], minor: [] }
      document.querySelectorAll('body *').forEach((el) => {
        if (el instanceof SVGElement) return // SVG chart labels are not DOM text
        const hasText = [...el.childNodes].some(
          (n) => n.nodeType === 3 && n.textContent.trim(),
        )
        if (!hasText || !visible(el)) return
        const cs = getComputedStyle(el)
        if (cs.position === 'absolute' && el.className.toString().includes('sr-only'))
          return
        const fs = parseFloat(cs.fontSize)
        if (fs && fs < 12)
          (fs < 10 ? tiny.severe : tiny.minor).push(`${fs}px  ${label(el)}`)
      })

      const noAlt = []
      document.querySelectorAll('img').forEach((el) => {
        if (visible(el) && !el.hasAttribute('alt')) noAlt.push(label(el))
      })

      const edge = []
      document.querySelectorAll('h1, h2, p, button, a').forEach((el) => {
        if (!visible(el)) return
        const b = el.getBoundingClientRect()
        if (b.left < 4 && b.right > vw - 4 && b.width > vw * 0.7)
          edge.push(label(el))
      })

      const uniq = (a) => [...new Set(a)]
      return {
        tapSevere: uniq(tap.severe).slice(0, 10),
        tapMinor: uniq(tap.minor).slice(0, 10),
        tinySevere: uniq(tiny.severe).slice(0, 10),
        tinyMinor: uniq(tiny.minor).slice(0, 8),
        noAlt: uniq(noAlt).slice(0, 10),
        edge: uniq(edge).slice(0, 8),
      }
    })
    const sec = (title, arr) => {
      console.log(`\n${title}: ${arr.length}${arr.length ? '' : '  ✅'}`)
      arr.forEach((x) => console.log('  · ' + x))
    }
    sec('🔴 Tiny tap targets <24px (hard to tap)', r.tapSevere)
    sec('🟡 Tap targets 24-40px (usable, under the 44px guideline)', r.tapMinor)
    sec('🔴 Text <10px (illegible)', r.tinySevere)
    sec('🟡 Text 10-12px (review; captions are usually intentional)', r.tinyMinor)
    sec('🔴 Images without alt', r.noAlt)
    sec('🟡 Full-width text stuck to the edges (no padding)', r.edge)
  })
} else if (mode === 'a11y') {
  // Real WCAG audit with axe-core (standard engine): contrast, ARIA, labels,
  // roles, accessible names, etc. Injected from a CDN.
  const url = rest[0]
  const desktop = rest.includes('--desktop')
  await withPage(desktop ? DESKTOP : MOBILE, async (page) => {
    await load(page, url)
    await page
      .addScriptTag({
        url: 'https://cdn.jsdelivr.net/npm/axe-core@4.10.3/axe.min.js',
      })
      .catch(() => {})
    if (!(await page.evaluate(() => !!window.axe))) {
      console.log('Could not load axe-core (no network?). Try again.')
      return
    }
    const res = await page.evaluate(
      async () =>
        await window.axe.run(document, {
          runOnly: {
            type: 'tag',
            values: ['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa', 'best-practice'],
          },
        }),
    )
    const rank = { critical: 0, serious: 1, moderate: 2, minor: 3 }
    const icon = { critical: '🔴', serious: '🟠', moderate: '🟡', minor: '⚪' }
    const v = res.violations.sort(
      (a, b) => (rank[a.impact] ?? 9) - (rank[b.impact] ?? 9),
    )
    const nodes = v.reduce((n, x) => n + x.nodes.length, 0)
    console.log(
      `axe-core (${desktop ? 'desktop' : 'mobile'}): ${v.length} rules with violations, ${nodes} nodes\n`,
    )
    for (const x of v) {
      console.log(
        `${icon[x.impact] || '·'} [${x.impact}] ${x.id} — ${x.help}  (${x.nodes.length})`,
      )
      x.nodes.slice(0, 3).forEach((n) => {
        const hint = (n.failureSummary || '').split('\n')[1]?.trim() || ''
        console.log(`   ${n.target.join(' ')}${hint ? '  — ' + hint : ''}`)
      })
    }
    if (!v.length) console.log('✅ No WCAG violations detected by axe-core.')
  })
} else {
  console.log(
    'modes: shot | audit | bisect | checks | a11y | invisible | hydration | states | rhythm (see the script header)',
  )
  process.exit(1)
}
