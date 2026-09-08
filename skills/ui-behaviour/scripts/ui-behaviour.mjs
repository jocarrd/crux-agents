#!/usr/bin/env node
// ui-behaviour — comprobar que los controles hacen algo al pulsarlos.
//
//   node ui-behaviour.mjs sweep <url> [--mobile]
//   node ui-behaviour.mjs probe <url> "<texto del boton>" [--scope <sel>] [--mobile]
//
// sweep: pasada rapida sobre todos los controles, lista los sospechosos.
// probe: recarga, acota al componente y pulsa uno solo dos veces.
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
const movil = rest.includes('--mobile')
const url = rest[0]

// La huella: lo que el usuario veria cambiar. No el HTML entero, que cambia
// por motivos que no importan.
const HUELLA = () => {
  const t = (sel, n = 12) =>
    [...document.querySelectorAll(sel)].slice(0, n).map((e) => e.textContent.trim()).join('|')
  return {
    filas: [...document.querySelectorAll('table')].map((x) => x.querySelectorAll('tbody tr').length).join(','),
    primeraFila: t('table tbody tr:first-child td', 6),
    cabeceras: t('table thead th', 14),
    activos: [...document.querySelectorAll('.active, [aria-selected="true"], [aria-pressed="true"], [aria-current]')]
      .slice(0, 14)
      .map((e) => e.textContent.trim().slice(0, 22))
      .join('|'),
    contadores: t('[class*="pagination"], [class*="count"], [class*="footer"] span', 6),
    fichas: document.querySelectorAll('li, [class*="chip"], [class*="card"]').length,
    dialogos: document.querySelectorAll('dialog[open], [role="dialog"]').length,
    url: location.href,
  }
}

async function abrir(browser) {
  const ctx = await browser.newContext(movil ? MOBILE : DESKTOP)
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
  const page = await abrir(browser)
  const errs = []
  page.on('pageerror', (e) => errs.push(String(e).slice(0, 90)))
  const n = await page.$$eval('main button, main a[href]', (e) => e.length)
  const sospechosos = []
  let probados = 0
  for (let i = 0; i < n; i++) {
    const meta = await page.evaluate((idx) => {
      const e = [...document.querySelectorAll('main button, main a[href]')][idx]
      if (!e) return null
      const r = e.getBoundingClientRect()
      return {
        txt: (e.textContent || '').trim().slice(0, 30) || e.getAttribute('aria-label') || '(sin texto)',
        ok: r.width > 0 && r.height > 0 && !e.disabled && e.tagName === 'BUTTON',
      }
    }, i)
    if (!meta || !meta.ok) continue
    const antes = await page.evaluate(HUELLA)
    const el = (await page.$$('main button, main a[href]'))[i]
    await el.scrollIntoViewIfNeeded().catch(() => {})
    await el.click({ timeout: 2500 }).catch(() => {})
    await page.waitForTimeout(700)
    const dsp = await page.evaluate(HUELLA)
    probados++
    const cambia = Object.keys(antes).some((k) => antes[k] !== dsp[k])
    if (!cambia) sospechosos.push(meta.txt)
  }
  console.log(`${probados} controles pulsados · ${sospechosos.length} sin efecto aparente`)
  sospechosos.forEach((s) => console.log(`  ? ${s}`))
  console.log(
    sospechosos.length
      ? '\nSon SOSPECHOSOS, no fallos. Pasa cada uno por `probe` antes de reportarlo:\n' +
          'la pasada encadena clics, asi que muchos caen sobre un estado ya activo.'
      : '\nTodos producen algun cambio.',
  )
  console.log('errores de consola:', errs.length ? [...new Set(errs)] : 'ninguno')
} else if (mode === 'probe') {
  const texto = rest[1]
  const si = rest.indexOf('--scope')
  const scope = si >= 0 ? rest[si + 1] : 'main'
  const page = await abrir(browser)
  const sel = `${scope} button:has-text("${texto}")`
  const cuantos = await page.$$eval(sel, (e) => e.length).catch(() => 0)
  if (!cuantos) {
    console.log(`no encontrado: ${sel}`)
} else {
    if (cuantos > 1)
      console.log(`⚠  ${cuantos} controles coinciden con ${sel} — acota mas con --scope`)
    const el = await page.$(sel)
    const diff = (a, b) =>
      Object.keys(a)
        .filter((k) => a[k] !== b[k])
        .map((k) => `${k}: ${String(a[k]).slice(0, 44)} -> ${String(b[k]).slice(0, 44)}`)
    const h0 = await page.evaluate(HUELLA)
    await el.scrollIntoViewIfNeeded().catch(() => {})
    await el.click({ timeout: 3000 }).catch(() => {})
    await page.waitForTimeout(900)
    const h1 = await page.evaluate(HUELLA)
    const d1 = diff(h0, h1)
    console.log('1er clic:', d1.length ? '' : 'sin cambios')
    d1.forEach((l) => console.log('   ' + l))
    await el.click({ timeout: 3000 }).catch(() => {})
    await page.waitForTimeout(900)
    const h2 = await page.evaluate(HUELLA)
    const d2 = diff(h1, h2)
    console.log('2do clic:', d2.length ? '' : 'sin cambios')
    d2.forEach((l) => console.log('   ' + l))
    console.log(
      '\nSi el 1er clic no cambia nada pero el 2do si, el control funciona: el\n' +
        'primer estado coincidia con el que ya venia por defecto.',
    )
  }
} else if (mode === 'keyboard') {
// Tabular por la interfaz: lo que no recibe foco no existe para quien no
// usa raton. Y un anillo de foco invisible es lo mismo que no tenerlo.
const page = await abrir(browser)
await page.evaluate(() => window.scrollTo(0, 0))
await page.waitForTimeout(400)

const operables = await page.$$eval(
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

// Recorrido real con el tabulador
const visitados = []
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
      enMain: !!e.closest('main'),
      y: Math.round(r.top + window.scrollY),
      anillo:
        c.outlineStyle !== 'none' && parseFloat(c.outlineWidth) > 0
          ? 'outline'
          : c.boxShadow !== 'none'
            ? 'shadow'
            : 'ninguno',
    }
  })
  if (!f) break
  if (f.enMain) visitados.push(f)
}

const sinAnillo = visitados.filter((v) => v.anillo === 'ninguno')
let saltos = 0
for (let i = 1; i < visitados.length; i++)
  if (visitados[i].y < visitados[i - 1].y - 120) saltos++

console.log(`operables en main: ${operables.length}`)
console.log(`alcanzados con Tab: ${visitados.length}`)
console.log(`sin anillo de foco visible: ${sinAnillo.length}`)
console.log(`saltos hacia atras en el orden: ${saltos}`)
if (operables.length > visitados.length)
  console.log(
    `\n⚠  ${operables.length - visitados.length} controles operables no se alcanzaron tabulando.`,
  )
sinAnillo.slice(0, 10).forEach((v) => console.log(`  sin anillo: ${v.txt}`))
console.log(
  '\nOjo: los controles dentro de un contenedor que se desplaza necesitan\n' +
    'tabindex="0" en el contenedor, o la region no se puede recorrer con teclado.',
)
} else {
  console.log('modos: sweep <url> | probe <url> "<texto>" [--scope <sel>] | keyboard <url>')
  process.exit(1)
}

await browser.close()
