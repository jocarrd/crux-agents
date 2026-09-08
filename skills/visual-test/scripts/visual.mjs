#!/usr/bin/env node
// Testing visual headless con Chrome del sistema (vía playwright-core).
// Uso:
//   node visual.mjs shot   <url> <out.png> [--desktop] [--scroll N]
//   node visual.mjs audit  <url> [url...]          # scroll horizontal + culpables
//   node visual.mjs bisect <url> [--threshold N]   # localiza el elemento que desborda
//   node visual.mjs checks <url>                   # señales de diseño/usabilidad mobile
//   node visual.mjs a11y   <url> [--desktop]       # auditoría WCAG con axe-core (CDN)
//
// Requiere: google-chrome instalado y `npm i playwright-core` en el cwd.
// El modo a11y inyecta axe-core desde CDN (necesita red).
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
  // Dev (turbopack) compila al vuelo y a veces falla un chunk dinámico el 1er
  // intento: calentar dos veces.
  for (let i = 0; i < 2; i++) {
    await page
      .goto(url, { waitUntil: 'networkidle', timeout: 35000 })
      .catch(() => {})
    await page.waitForTimeout(i ? 2000 : 800)
  }
}

// --- recorrido como el de una persona -------------------------------------
// Las animaciones de entrada y las islas que hidratan tarde solo se ven si se
// baja con pausas. Un scroll de golpe mide el estado anterior.
async function recorrer(page, pasos = 60, salto = 500, espera = 150) {
  for (let i = 0; i < pasos; i++) {
    await page.evaluate((y) => window.scrollBy(0, y), salto)
    await page.waitForTimeout(espera)
  }
  await page.waitForTimeout(2500)
}

function relacionContraste(a, b) {
  const canal = (c) => {
    const m = c.match(/color\(srgb\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)/)
    if (m) return [+m[1], +m[2], +m[3]]
    const n = c.match(/[\d.]+/g)
    return n ? n.slice(0, 3).map((x) => +x / 255) : [0, 0, 0]
  }
  const lum = (c) => {
    const [r, g, bl] = canal(c).map((n) =>
      n <= 0.03928 ? n / 12.92 : ((n + 0.055) / 1.055) ** 2.4,
    )
    return 0.2126 * r + 0.7152 * g + 0.0722 * bl
  }
  const la = lum(a)
  const lb = lum(b)
  return +((Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05)).toFixed(2)
}

if (mode === 'invisible') {
  // Una animación de entrada que no dispara deja el contenido en opacity 0
  // para siempre. No lo ve el build, ni el typecheck, ni axe.
  const urls = rest.filter((r) => !r.startsWith('--'))
  const desktop = rest.includes('--desktop')
  let malos = 0
  await withPage(desktop ? DESKTOP : MOBILE, async (page) => {
    for (const url of urls) {
      await load(page, url)
      await recorrer(page)
      const ocultos = await page.evaluate(() => {
        const dentroDeCarrusel = (e) => !!e.closest('.swiper, [data-carousel]')
        return [...document.querySelectorAll('main *')]
          .filter((e) => {
            if (dentroDeCarrusel(e)) return false
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
      if (ocultos.length) {
        malos++
        console.log(`🔴 ${url} — ${ocultos.length} elementos invisibles`)
        ocultos.forEach((o) => console.log(`   ${o}`))
      } else console.log(`✅ ${url} — nada invisible`)
    }
  })
  if (malos) process.exit(1)
} else if (mode === 'hydration') {
  // Un fallo de hidratación hace que el framework tire el HTML del servidor y
  // repinte en cliente. Solo se ve escuchando pageerror mientras se recorre.
  const urls = rest.filter((r) => !r.startsWith('--'))
  const desktop = rest.includes('--desktop')
  let malos = 0
  await withPage(desktop ? DESKTOP : MOBILE, async (page) => {
    for (const url of urls) {
      const errs = []
      page.on('pageerror', (e) => errs.push(String(e).slice(0, 120)))
      page.on('console', (m) => {
        if (m.type() === 'error') errs.push('console: ' + m.text().slice(0, 120))
      })
      await load(page, url)
      await recorrer(page, 45, 500, 120)
      if (errs.length) {
        malos++
        console.log(`🔴 ${url}`)
        ;[...new Set(errs)].slice(0, 5).forEach((e) => console.log(`   ${e}`))
      } else console.log(`✅ ${url} — sin errores en consola`)
      page.removeAllListeners('pageerror')
      page.removeAllListeners('console')
    }
  })
  if (malos) process.exit(1)
} else if (mode === 'states') {
  // axe mide el estado en reposo. Un botón puede pasar parado y fallar al
  // pasar el ratón o al quedarse activo, y eso no lo ve nadie.
  const url = rest[0]
  const desktop = !rest.includes('--mobile')
  await withPage(desktop ? DESKTOP : MOBILE, async (page) => {
    await load(page, url)
    await recorrer(page, 40, 450, 130)
    const n = await page.$$eval('main button, main a[href]', (e) => e.length)
    const filas = []
    for (let i = 0; i < n; i++) {
      const el = (await page.$$('main button, main a[href]'))[i]
      if (!el) continue
      const meta = await page.evaluate((idx) => {
        const e = [...document.querySelectorAll('main button, main a[href]')][idx]
        const r = e.getBoundingClientRect()
        return {
          txt: (e.textContent || '').trim().slice(0, 28) || e.getAttribute('aria-label') || '(sin texto)',
          ok: r.width > 0 && r.height > 0 && !e.disabled,
        }
      }, i)
      if (!meta.ok) continue
      const leer = () =>
        page.evaluate((idx) => {
          const e = [...document.querySelectorAll('main button, main a[href]')][idx]
          const c = getComputedStyle(e)
          let fondo = c.backgroundColor
          let nodo = e
          while (fondo === 'rgba(0, 0, 0, 0)' && nodo.parentElement) {
            nodo = nodo.parentElement
            fondo = getComputedStyle(nodo).backgroundColor
          }
          return { color: c.color, fondo, cursor: c.cursor }
        }, i)
      await el.scrollIntoViewIfNeeded().catch(() => {})
      await page.mouse.move(2, 2)
      await page.waitForTimeout(450)
      const reposo = await leer()
      await el.hover({ timeout: 2000 }).catch(() => {})
      await page.waitForTimeout(500)
      const hover = await leer()
      filas.push({
        txt: meta.txt,
        reposo: relacionContraste(reposo.color, reposo.fondo),
        hover: relacionContraste(hover.color, hover.fondo),
        cursor: hover.cursor,
      })
    }
    const malos = filas.filter((f) => f.reposo < 4.5 || f.hover < 4.5)
    console.log(`${filas.length} controles · ${malos.length} por debajo de 4.5`)
    malos.forEach((f) =>
      console.log(`🔴 "${f.txt}" reposo:${f.reposo} hover:${f.hover}`),
    )
    if (!malos.length) console.log('✅ todos pasan AA en reposo y en hover')
    console.log(
      '\nOjo: los estados que solo existen al pulsar (pestaña activa, chip',
    )
    console.log('seleccionado) hay que activarlos y volver a medir a mano.')
  })
} else if (mode === 'rhythm') {
  // El aire entre secciones y el que queda donde cambia la banda de fondo.
  const url = rest[0]
  const desktop = !rest.includes('--mobile')
  await withPage(desktop ? DESKTOP : MOBILE, async (page) => {
    await load(page, url)
    await recorrer(page, 30, 600, 100)
    await page.evaluate(() => window.scrollTo(0, 0))
    await page.waitForTimeout(700)
    const filas = await page.evaluate(() => {
      const secs = [...document.querySelectorAll('main section, main > div')]
      return secs.map((s, i) => {
        const c = getComputedStyle(s)
        const r = s.getBoundingClientRect()
        const sig = secs[i + 1]
        const cab = s.querySelector('h1, h2, h3, header')
        return {
          que: (s.id || (s.className || '').toString().split(' ')[0] || '?').slice(0, 26),
          fondo: c.backgroundColor,
          padT: Math.round(parseFloat(c.paddingTop)),
          padB: Math.round(parseFloat(c.paddingBottom)),
          aire: sig
            ? Math.round(
                sig.getBoundingClientRect().top - r.bottom +
                  parseFloat(c.paddingBottom) +
                  parseFloat(getComputedStyle(sig).paddingTop),
              )
            : null,
          alTitulo: cab ? Math.round(cab.getBoundingClientRect().top - r.top) : null,
          cambiaFondo: sig ? getComputedStyle(sig).backgroundColor !== c.backgroundColor : false,
        }
      })
    })
    console.log('sección                     fondo                padT  padB   aire  al titular')
    filas.forEach((f) =>
      console.log(
        `${f.que.padEnd(27)} ${f.fondo.padEnd(20)} ${String(f.padT).padStart(4)} ${String(f.padB).padStart(5)} ${String(f.aire ?? '-').padStart(6)} ${String(f.alTitulo ?? '-').padStart(11)}` +
          (f.cambiaFondo && f.padB === 0 ? '  ← el fondo cambia y no hay aire' : ''),
      ),
    )
    const pegados = filas.filter((f) => f.alTitulo !== null && f.alTitulo < 24 && f.padT < 24)
    if (pegados.length)
      console.log(`\n🔴 ${pegados.length} secciones con el titular pegado al canto`)
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
    console.log(`scrollWidth base=${r.base} (hoja kids=0 = culpable real)`)
    r.hits.forEach((h) => console.log(`  -${h.drop}px kids=${h.kids} <${h.tag}> .${h.cls}${h.txt ? '  "' + h.txt + '"' : ''}`))
  })
} else if (mode === 'checks') {
  // Señales objetivas de diseño/usabilidad en móvil (no sustituye el ojo).
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

      // Tap targets: solo cuentan los "tipo botón" (pill/chip/control con caja:
      // fondo, borde o padding propio). Los links de texto en flujo (sin caja)
      // se tocan tocando el texto y NO se miden con la regla de 44px.
      const transparent = (c) => !c || c === 'transparent' || /, 0\)$/.test(c)
      const hasBox = (el, cs) =>
        el.tagName === 'INPUT' ||
        el.tagName === 'SELECT' ||
        parseFloat(cs.borderTopWidth) > 0 ||
        parseFloat(cs.borderBottomWidth) > 0 ||
        !transparent(cs.backgroundColor) ||
        cs.backgroundImage !== 'none'
      const tap = { serio: [], menor: [] }
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
            // diminuto: solo es problema si es "tipo botón" (con caja). Un link
            // de texto sin fondo/borde se toca tocando el texto: no se cuenta.
            if (hasBox(el, cs)) tap.serio.push(entry)
          } else {
            tap.menor.push(entry)
          }
        })

      // Texto: <10px casi siempre es problema; 10-12px suele ser leyenda/etiqueta
      // secundaria intencionada (a revisar, no alarma).
      const tiny = { serio: [], menor: [] }
      document.querySelectorAll('body *').forEach((el) => {
        if (el instanceof SVGElement) return // labels de gráficos SVG no son texto DOM
        const hasText = [...el.childNodes].some(
          (n) => n.nodeType === 3 && n.textContent.trim(),
        )
        if (!hasText || !visible(el)) return
        const cs = getComputedStyle(el)
        if (cs.position === 'absolute' && el.className.toString().includes('sr-only'))
          return
        const fs = parseFloat(cs.fontSize)
        if (fs && fs < 12)
          (fs < 10 ? tiny.serio : tiny.menor).push(`${fs}px  ${label(el)}`)
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
        tapSerio: uniq(tap.serio).slice(0, 10),
        tapMenor: uniq(tap.menor).slice(0, 10),
        tinySerio: uniq(tiny.serio).slice(0, 10),
        tinyMenor: uniq(tiny.menor).slice(0, 8),
        noAlt: uniq(noAlt).slice(0, 10),
        edge: uniq(edge).slice(0, 8),
      }
    })
    const sec = (title, arr) => {
      console.log(`\n${title}: ${arr.length}${arr.length ? '' : '  ✅'}`)
      arr.forEach((x) => console.log('  · ' + x))
    }
    sec('🔴 Tap targets diminutos <24px (difíciles de tocar)', r.tapSerio)
    sec('🟡 Tap targets 24-40px (usables, bajo la guía de 44px)', r.tapMenor)
    sec('🔴 Texto <10px (ilegible)', r.tinySerio)
    sec('🟡 Texto 10-12px (revisar; leyendas suelen ser intencionadas)', r.tinyMenor)
    sec('🔴 Imágenes sin alt', r.noAlt)
    sec('🟡 Texto a ancho completo pegado a los bordes (sin padding)', r.edge)
  })
} else if (mode === 'a11y') {
  // Auditoría WCAG real con axe-core (motor estándar): contraste, ARIA,
  // labels, roles, nombres accesibles, etc. Se inyecta desde CDN.
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
      console.log('No se pudo cargar axe-core (¿sin red?). Reintenta.')
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
      `axe-core (${desktop ? 'desktop' : 'mobile'}): ${v.length} reglas con violaciones, ${nodes} nodos\n`,
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
    if (!v.length) console.log('✅ Sin violaciones WCAG detectadas por axe-core.')
  })
} else {
  console.log(
    'modos: shot | audit | bisect | checks | a11y | invisible | hydration | states | rhythm (ver cabecera del script)',
  )
  process.exit(1)
}
