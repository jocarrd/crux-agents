#!/usr/bin/env node
// Captura las mismas páginas en dos versiones —la publicada y la nueva— para
// montar el antes y el después.
//
//   node capture.mjs --base <url> --head <url> --paths /,/ficha \
//     --widths 1440,820,390 --out <carpeta> [--cookie nombre=valor] [--wait 3000] \
//     [--hide '<selectores css>']
//
// Deja <carpeta>/before/<página>-<ancho>.png y <carpeta>/after/<página>-<ancho>.png.
// Requiere `npm i playwright-core` en el cwd, como visual-test.
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
    console.error(`falta --${required}`)
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

// Con un servidor de desarrollo, el Chrome del sistema puede quedarse sin
// pintar nunca (una transición de vista que no termina). El navegador que
// trae Playwright no lo tiene, así que va primero si está instalado.
async function launch() {
  try {
    return await chromium.launch()
  } catch {
    if (!CHROME) throw new Error('no hay navegador: instala uno o define CHROME_BIN')
    return chromium.launch({ executablePath: CHROME, args: ['--no-sandbox'] })
  }
}

const slug = (path) =>
  path.replace(/^\/+|\/+$/g, '').replace(/[^a-z0-9]+/gi, '-').toLowerCase() || 'inicio'

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
  // Avisos de cookies, burbujas de chat y demás capas flotantes tapan la página
  // en todos los tramos; cada web guarda el consentimiento a su manera, así que
  // se ocultan por selector en vez de intentar aceptarlos.
  if (args.hide) {
    await page.addStyleTag({ content: `${args.hide} { display: none !important }` })
  }
  // Recorrer despierta lo que carga al entrar en pantalla.
  await page.evaluate(async () => {
    for (let y = 0; y < document.documentElement.scrollHeight; y += 600) {
      scrollTo(0, y)
      await new Promise((r) => setTimeout(r, 120))
    }
    scrollTo(0, 0)
  })
  const height = await page.evaluate(() => document.documentElement.scrollHeight)
  // La captura de página completa cambia el tamaño de la ventana, y las
  // gráficas que se redibujan al cambiar de tamaño reinician su animación: la
  // foto las pilla vacías. Se agranda antes, se espera y después se dispara.
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
