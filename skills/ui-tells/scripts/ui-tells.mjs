#!/usr/bin/env node
// Marcadores de interfaz generada, medidos sobre la página renderizada.
// Uso:
//   node ui-tells.mjs revisar <url> [url...]   # cuenta los marcadores
//   node ui-tells.mjs detalle <url>            # enseña cada caso con su texto
//
// Requiere: google-chrome instalado y `npm i playwright-core` en el cwd.
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

// Los que puntúan son fallos objetivos: o el texto cabe o no cabe, o la
// navegación ocupa 80px o no. Los que solo informan dependen del criterio de
// quien diseña, y una expresión regular no puede decidir por él.
const PUNTUAN = ['rayaLarga', 'heroFuera', 'navAlta', 'ctaPartido', 'alturaFija']
const INFORMAN = [
  'tresIguales',
  'eyebrows',
  'puntoMedio',
  'eyebrowNumerada',
  'cromoFalso',
  'scrollCue',
  'versionEnHero',
  'nombreGenerico',
  'cifraRedonda',
  'verboRelleno',
]

const ETIQUETAS = {
  rayaLarga: 'Raya larga (— o –) en texto visible',
  heroFuera: 'El titular o la llamada a la acción no caben en la primera pantalla',
  navAlta: 'Navegación de más de 80px o partida en dos líneas',
  ctaPartido: 'Etiqueta de un botón partida en dos líneas',
  alturaFija: 'Altura 100vh en vez de 100dvh',
  tresIguales: 'Rejilla de tres columnas iguales',
  eyebrows: 'Antetítulos en versalita por encima del tope',
  puntoMedio: 'Líneas con más de un punto medio (·)',
  eyebrowNumerada: 'Antetítulo numerado (001 ·, 00 / INDEX)',
  cromoFalso: 'Ventana falsa dibujada con divs',
  scrollCue: 'Indicación de «scroll» escrita',
  versionEnHero: 'Etiqueta de versión o beta en la primera pantalla',
  nombreGenerico: 'Nombre o marca de relleno (Acme, John Doe, Lorem)',
  cifraRedonda: 'Cifra falsamente redonda (99,9 %, 50 %, 10.000)',
  verboRelleno: 'Verbo de folleto (impulsar, potenciar, unleash, seamless)',
}

const MEDIDA = `(() => {
  const visible = (e) => {
    const s = getComputedStyle(e)
    if (s.display === 'none' || s.visibility === 'hidden' || +s.opacity === 0) return false
    const r = e.getBoundingClientRect()
    return r.width > 0 && r.height > 0
  }
  const hojas = () => {
    let css = ''
    for (const h of document.styleSheets) {
      try {
        for (const r of h.cssRules) css += r.cssText
      } catch (e) {}
    }
    return css
  }
  const texto = document.body.innerText
  const lineas = texto.split('\\n').map((l) => l.trim()).filter(Boolean)
  const todos = [...document.querySelectorAll('body *')].filter(visible)
  const hojas_css = hojas()
  const alto = innerHeight
  const casos = {}
  const anota = (clave, muestra) => {
    casos[clave] = casos[clave] || []
    if (casos[clave].length < 12) casos[clave].push(String(muestra).slice(0, 110))
  }

  for (const l of lineas) if (/[—–]/.test(l)) anota('rayaLarga', l)

  const h1 = document.querySelector('h1')
  if (h1) {
    const r = h1.getBoundingClientRect()
    if (r.bottom > alto) anota('heroFuera', 'el h1 termina en ' + Math.round(r.bottom) + 'px')
    const cta = [...document.querySelectorAll('a,button')].filter(visible).find((e) => {
      const c = e.getBoundingClientRect()
      return c.top > r.top && (e.innerText || '').trim().length > 1
    })
    if (cta && cta.getBoundingClientRect().bottom > alto) {
      anota('heroFuera', 'la primera llamada a la acción cae fuera: ' + cta.innerText.trim())
    }
  }

  const nav = document.querySelector('header nav, nav, header')
  if (nav && visible(nav)) {
    const r = nav.getBoundingClientRect()
    if (r.height > 80) anota('navAlta', Math.round(r.height) + 'px de alto')
    // Dos enlaces están en filas distintas solo si los separa más de media
    // altura de enlace. Unos pocos píxeles son alineación, no salto de línea.
    const enlaces = [...nav.querySelectorAll('a')].filter(visible)
    const cajas = enlaces.map((a) => a.getBoundingClientRect())
    const holgura = Math.max(12, Math.max(...cajas.map((c) => c.height), 0) / 2)
    const filas = []
    for (const c of cajas.sort((a, b) => a.top - b.top)) {
      if (!filas.length || c.top - filas[filas.length - 1] > holgura) filas.push(c.top)
    }
    if (enlaces.length > 2 && filas.length > 1) {
      anota('navAlta', 'los enlaces ocupan ' + filas.length + ' filas')
    }
  }

  // Contar rectángulos de un rango sobre el propio texto es lo único que
  // distingue una etiqueta partida de uná con mucho relleno vertical.
  const filasDeTexto = (e) => {
    let filas = 0
    for (const n of e.childNodes) {
      if (n.nodeType !== 3 || !n.textContent.trim()) continue
      const r = document.createRange()
      r.selectNodeContents(n)
      const cajas = [...r.getClientRects()].filter((c) => c.width > 1 && c.height > 1)
      const tops = new Set(cajas.map((c) => Math.round(c.top / 4)))
      filas = Math.max(filas, tops.size)
    }
    return filas
  }
  for (const e of [...document.querySelectorAll('a,button')].filter(visible)) {
    const t = (e.innerText || '').trim()
    if (!t || t.length > 40 || t.includes('\\n')) continue
    if (filasDeTexto(e) > 1) anota('ctaPartido', t)
  }

  // 100vh no encoge cuando el navegador móvil esconde la barra de direcciones,
  // así que el contenido pega un salto. 100dvh sí. calc() sobre 100vh cuenta
  // igual: arrastra el mismo error.
  for (const trozo of hojas_css.match(/[^{}]+\\{[^{}]*100vh[^{}]*\\}/g) || []) {
    anota('alturaFija', trozo.replace(/\\s+/g, ' ').slice(0, 100))
  }

  for (const e of todos) {
    const s = getComputedStyle(e)
    if (s.display !== 'grid') continue
    const cols = s.gridTemplateColumns.split(' ').filter(Boolean)
    if (cols.length !== 3) continue
    if (new Set(cols.map((c) => Math.round(parseFloat(c)))).size !== 1) continue
    if (e.children.length !== 3) continue
    anota('tresIguales', (e.innerText || '').replace(/\\s+/g, ' ').slice(0, 90))
  }

  const secciones = Math.max(1, document.querySelectorAll('section').length)
  const tope = Math.ceil(secciones / 3)
  const cejas = todos.filter((e) => {
    if (e.children.length) return false
    const t = (e.textContent || '').trim()
    if (t.length < 2 || t.length > 42) return false
    const s = getComputedStyle(e)
    const mayus = s.textTransform === 'uppercase' || (t === t.toUpperCase() && /[A-ZÁÉÍÓÚÑ]/.test(t))
    return mayus && parseFloat(s.letterSpacing) > 0.8
  })
  for (const c of cejas) {
    const t = c.textContent.trim()
    if (/^[0-9]{2,3}\\s*[\\/·.-]|^[0-9]{2,3}\\s+[A-Za-zÁ-Úá-ú]/.test(t)) anota('eyebrowNumerada', t)
  }
  if (cejas.length > tope) {
    anota('eyebrows', cejas.length + ' antetítulos para ' + secciones + ' secciones (tope ' + tope + ')')
  }

  for (const l of lineas) if ((l.match(/·/g) || []).length > 1) anota('puntoMedio', l)

  for (const e of todos) {
    const hijos = [...e.children].filter(visible)
    if (hijos.length < 3) continue
    const puntos = hijos.filter((h) => {
      const r = h.getBoundingClientRect()
      const s = getComputedStyle(h)
      return r.width < 18 && r.height < 18 && Math.abs(r.width - r.height) < 4 &&
        parseFloat(s.borderRadius) >= r.width / 2 - 1 && !(h.innerText || '').trim()
    })
    if (puntos.length < 3) continue
    const y = new Set(puntos.map((p) => Math.round(p.getBoundingClientRect().top)))
    if (y.size !== 1) continue
    // Un marco de ventana alrededor de una captura real es legítimo. El tell es
    // dibujar la interfaz entera con divs, sin imagen ninguna dentro.
    const marco = e.closest('figure, div, section') || e
    const raiz = marco.parentElement || marco
    if (raiz.querySelector('img, canvas, video, picture, svg image')) continue
    anota('cromoFalso', (raiz.innerText || '').replace(/\\s+/g, ' ').slice(0, 80) || 'ventana dibujada con divs')
  }

  for (const l of lineas) {
    if (/^(scroll|desliza|↓\\s*scroll|scroll to explore|scroll para)\\b/i.test(l) && l.length < 30) {
      anota('scrollCue', l)
    }
  }

  for (const e of todos) {
    if (e.getBoundingClientRect().top > alto) continue
    const t = (e.textContent || '').trim()
    if (e.children.length || t.length > 26) continue
    if (/\\b(beta|alpha|early access|invite[- ]only|v\\d+(\\.\\d+)+|rc\\.\\d+)\\b/i.test(t)) {
      anota('versionEnHero', t)
    }
  }

  const genericos = /\\b(acme|john doe|jane doe|jack su|sarah chan|lorem ipsum|nexus|smartflow|cloudly|example\\.com|foo ?bar)\\b/i
  for (const l of lineas) if (genericos.test(l)) anota('nombreGenerico', l)

  for (const l of lineas) {
    if (/(^|\\s)(99[.,]9{1,2}\\s?%|100\\s?%|50\\s?%|10\\.000|1\\.000\\.000|1234567)(\\s|$)/.test(l) && l.length < 60) {
      anota('cifraRedonda', l)
    }
  }

  const relleno = /\\b(impulsar|potenciar|revolucionar|desbloquear|empoderar|sin fisuras|de nueva generaci[oó]n|elevate|unleash|seamless|next[- ]gen|revolutioniz\\w*|supercharge|empower)\\b/i
  for (const l of lineas) if (relleno.test(l)) anota('verboRelleno', l)

  return { casos, secciones, lineas: lineas.length }
})()`

async function medir(url) {
  const browser = await chromium.launch({
    executablePath: CHROME,
    args: ['--no-sandbox'],
  })
  try {
    const ctx = await browser.newContext(DESKTOP)
    const page = await ctx.newPage()
    await page.goto(url, { waitUntil: 'networkidle', timeout: 45000 })
    await page.waitForTimeout(900)
    return await page.evaluate(MEDIDA)
  } finally {
    await browser.close()
  }
}

function fila(clave, n) {
  const marca = n === 0 ? '   ' : PUNTUAN.includes(clave) ? '🔴 ' : '⚠️  '
  return `${marca}${String(n).padStart(3)}  ${ETIQUETAS[clave]}`
}

function informe(url, r, detalle) {
  const carga = PUNTUAN.reduce((s, k) => s + (r.casos[k]?.length || 0), 0)
  const avisos = INFORMAN.reduce((s, k) => s + (r.casos[k]?.length || 0), 0)

  console.log(`\n${url}`)
  console.log(`${r.lineas} líneas de texto · ${r.secciones} secciones\n`)
  console.log('  fallos objetivos')
  for (const k of PUNTUAN) console.log('  ' + fila(k, r.casos[k]?.length || 0))
  console.log('\n  indicios, decide tú')
  for (const k of INFORMAN) console.log('  ' + fila(k, r.casos[k]?.length || 0))

  if (detalle) {
    console.log('')
    for (const k of [...PUNTUAN, ...INFORMAN]) {
      const casos = r.casos[k]
      if (!casos?.length) continue
      console.log(`\n  ${ETIQUETAS[k]}`)
      for (const c of casos) console.log('    · ' + c)
    }
  }

  console.log(
    `\ncarga ${carga} · ${avisos} indicios — ` +
      (carga === 0
        ? avisos === 0
          ? 'limpio'
          : 'sin fallos objetivos, mira los indicios'
        : 'hay fallos que arreglar'),
  )
  return carga
}

const [modo, ...urls] = process.argv.slice(2)
if (!modo || !urls.length || !['revisar', 'detalle'].includes(modo)) {
  console.log('uso: ui-tells.mjs revisar <url> [url...]  |  ui-tells.mjs detalle <url>')
  process.exit(2)
}

let peor = 0
for (const url of urls) {
  const r = await medir(url)
  peor = Math.max(peor, informe(url, r, modo === 'detalle'))
}
console.log(
  '\nLos fallos objetivos se arreglan. Los indicios son criterio: una rejilla de\n' +
    'tres columnas puede ser exactamente lo que pide el contenido.',
)
process.exit(peor > 0 ? 1 : 0)
