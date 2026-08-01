#!/usr/bin/env node
// Mide la salud estructural de un repo y su tendencia.
//
//   health.mjs [ruta] [--save] [--json] [--top N]
//
// No revisa el diff: eso ya lo hace la revisión de código. Mide **el conjunto**,
// que es lo que nadie mira y lo que se erosiona despacio. Sin dependencias: lo
// que necesita son ficheros y git.
//
// Con --save guarda la línea base. A partir de ahí la pregunta deja de ser
// "¿está bien esto?" y pasa a ser "¿está peor que la última vez?", que es la
// única que se puede responder sin discutir umbrales.

import { readFileSync, writeFileSync, existsSync, readdirSync, statSync } from 'node:fs'
import { join, relative, extname } from 'node:path'
import { execSync } from 'node:child_process'

const args = process.argv.slice(2)
const ROOT = args.find(a => !a.startsWith('--')) || process.cwd()
const SAVE = args.includes('--save')
const JSON_OUT = args.includes('--json')
const TOP = Number((args.find(a => a.startsWith('--top')) || '').split('=')[1] || 8)
const CON_TESTS = args.includes('--tests')
const MASA_MIN = Number((args.find(a => a.startsWith('--masa')) || '').split('=')[1] || 200)
const BASELINE = join(ROOT, '.crux-health.json')

const CODIGO = new Set(['.ts', '.tsx', '.js', '.jsx', '.mjs', '.py', '.go', '.rs', '.java', '.rb'])
const IGNORAR = new Set(['node_modules', '.git', 'dist', 'build', '.next', 'coverage',
  'vendor', '__pycache__', '.venv', 'target', 'out', '.turbo', 'migrations'])

function ficheros(dir, acc = []) {
  let entradas
  try { entradas = readdirSync(dir, { withFileTypes: true }) } catch { return acc }
  for (const e of entradas) {
    if (e.name.startsWith('.') && e.name !== '.claude') continue
    if (IGNORAR.has(e.name)) continue
    const full = join(dir, e.name)
    const esTest = /(^|\/)(__tests__|tests?|spec)(\/|$)/.test(full) || /\.(test|spec)\.[a-z]+$/.test(e.name)
    if (esTest && !CON_TESTS) continue
    if (e.isDirectory()) ficheros(full, acc)
    else if (CODIGO.has(extname(e.name))) acc.push(full)
  }
  return acc
}

// Normaliza para que la duplicación no dependa del formateo ni de los nombres
// de variable locales, que es lo que hace inútil un diff textual.
const normaliza = (l) => l.trim().replace(/\s+/g, ' ')
// Una línea cuenta si aporta lógica propia. Descartamos lo que se repite por
// fuerza del lenguaje —llaves, imports, comentarios— porque si no, el informe
// se llena de falsos positivos y deja de leerse.
const estructural = (l) =>
  /^[)\]}{;,]+$/.test(l) ||
  /^(import|from|export|package|use|#include)\b/.test(l) ||
  l.startsWith('//') || l.startsWith('#') || /^[*]|^\/\*/.test(l)

const sustantiva = (l) => l.length >= 15 && !estructural(l)

// Y con lógica de verdad: sin esto, un objeto literal o una lista de campos
// repetida cuenta como código duplicado.
const conLogica = (l) =>
  !estructural(l) &&
  /\b(if|for|while|return|await|throw|catch|switch|case|function|def|const|let|var)\b|=>|[=<>!+\-*/%&|?]/.test(l)

function duplicacion(files, ventana = 6) {
  const bloques = new Map()
  for (const f of files) {
    const lineas = readFileSync(f, 'utf8').split('\n').map(normaliza)
    for (let i = 0; i + ventana <= lineas.length; i++) {
      const trozo = lineas.slice(i, i + ventana)
      // Masa mínima de contenido propio: un bloque de manejo de errores
      // genérico tiene pocas líneas sustantivas y cortas, y sin este umbral
      // satura el informe con el mismo patrón repetido en cada fichero.
      const masa = trozo.filter(sustantiva).reduce((n, l) => n + l.length, 0)
      if (masa < MASA_MIN) continue
      if (trozo.filter(conLogica).length < 3) continue
      const clave = trozo.join('\u0001')
      if (!bloques.has(clave)) bloques.set(clave, [])
      bloques.get(clave).push({ file: f, line: i + 1 })
    }
  }
  const grupos = []
  for (const [clave, sitios] of bloques) {
    if (sitios.length < 2) continue
    // Solapados dentro del mismo fichero cuentan una vez: si no, un bloque
    // repetido de 20 líneas aparece 15 veces y el informe deja de servir.
    const vistos = []
    for (const s of sitios) {
      if (vistos.some(v => v.file === s.file && Math.abs(v.line - s.line) < ventana)) continue
      vistos.push(s)
    }
    if (vistos.length >= 2) grupos.push({ lineas: ventana, sitios: vistos, muestra: clave.split('\u0001')[0] })
  }
  // Un bloque duplicado de 12 líneas aparece aquí como 7 ventanas contiguas.
  // Sin fusionarlas, el informe repite el mismo hallazgo siete veces y el
  // tamaño real del bloque —que es lo que dice cuánto duele— se pierde.
  const porFirma = new Map()
  for (const g of grupos) {
    const firma = g.sitios.map(s => s.file).sort().join('|')
    if (!porFirma.has(firma)) porFirma.set(firma, [])
    porFirma.get(firma).push(g)
  }

  const fusionados = []
  for (const lista of porFirma.values()) {
    lista.sort((a, b) => a.sitios[0].line - b.sitios[0].line)
    let actual = null
    for (const g of lista) {
      const contiguo = actual && g.sitios.every((s, i) => {
        const prev = actual.sitios.find(p => p.file === s.file)
        return prev && s.line - prev.line === actual.lineas - ventana + 1
      })
      if (contiguo) actual.lineas++
      else { if (actual) fusionados.push(actual); actual = { ...g, sitios: [...g.sitios] } }
    }
    if (actual) fusionados.push(actual)
  }

  return fusionados.sort((a, b) =>
    (b.sitios.length * b.lineas) - (a.sitios.length * a.lineas))
}

function complejidad(files) {
  const largas = []
  const anidadas = []
  const decl = /^\s*(export\s+)?(async\s+)?(function|def|func|fn|public|private|protected)?\s*[\w.]*\s*[({]/
  for (const f of files) {
    const lineas = readFileSync(f, 'utf8').split('\n')
    let inicio = null, base = 0, maxProf = 0
    lineas.forEach((l, i) => {
      if (!l.trim()) return
      const prof = Math.floor((l.match(/^[ \t]*/)[0].replace(/\t/g, '  ').length) / 2)
      maxProf = Math.max(maxProf, prof)
      if (inicio === null && decl.test(l) && prof <= 2) { inicio = i; base = prof }
      else if (inicio !== null && prof <= base && l.trim() && i > inicio + 2) {
        const largo = i - inicio
        const cuerpo = lineas.slice(inicio, i)
        const ramas = cuerpo.filter(x => /\b(if|for|while|switch|catch|\?\.|&&|\|\|)\b/.test(x)).length
        // Un bloque largo sin ramas es un catálogo de datos: largo no es complejo.
        if (largo > 60 && ramas >= 5) largas.push({ file: f, line: inicio + 1, lineas: largo, ramas })
        inicio = null
      }
    })
    if (maxProf >= 7) anidadas.push({ file: f, profundidad: maxProf })
  }
  return { largas: largas.sort((a, b) => b.lineas - a.lineas), anidadas: anidadas.sort((a, b) => b.profundidad - a.profundidad) }
}

function exportsHuerfanos(files) {
  const exportados = new Map()
  const importados = new Set()
  for (const f of files) {
    const src = readFileSync(f, 'utf8')
    for (const m of src.matchAll(/^export\s+(?:async\s+)?(?:const|function|class|type|interface|enum)\s+(\w+)/gm)) {
      exportados.set(m[1], f)
    }
    for (const m of src.matchAll(/import\s+(?:type\s+)?\{([^}]+)\}/g)) {
      for (const n of m[1].split(',')) importados.add(n.trim().split(/\s+as\s+/)[0].trim())
    }
    for (const m of src.matchAll(/import\s+(\w+)\s+from/g)) importados.add(m[1])
  }
  return [...exportados].filter(([n]) => !importados.has(n)).map(([n, f]) => ({ nombre: n, file: f }))
}

function depsSinUsar(root, files) {
  const pkg = join(root, 'package.json')
  if (!existsSync(pkg)) return []
  let deps
  try { deps = Object.keys(JSON.parse(readFileSync(pkg, 'utf8')).dependencies || {}) } catch { return [] }
  const src = files.map(f => readFileSync(f, 'utf8')).join('\n')
  return deps.filter(d => !new RegExp(`['"\`]${d.replace(/[/\\^$*+?.()|[\]{}]/g, '\\$&')}(/|['"\`])`).test(src))
}

function churn(root, dias = 90) {
  try {
    const out = execSync(`git -C "${root}" log --since="${dias} days ago" --numstat --format=""`,
      { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] })
    const cuenta = new Map()
    for (const l of out.split('\n')) {
      const [a, b, f] = l.split('\t')
      if (!f || !CODIGO.has(extname(f))) continue
      cuenta.set(f, (cuenta.get(f) || 0) + (Number(a) || 0) + (Number(b) || 0))
    }
    return [...cuenta].sort((a, b) => b[1] - a[1]).map(([file, lineas]) => ({ file, lineas }))
  } catch { return [] }
}

// --- Medición ----------------------------------------------------------------

const files = ficheros(ROOT)
if (!files.length) {
  console.log(`sin ficheros de código bajo ${ROOT}`)
  process.exit(0)
}

const rel = (f) => relative(ROOT, f)
const dup = duplicacion(files)
const { largas, anidadas } = complejidad(files)
const huerfanos = exportsHuerfanos(files)
const deps = depsSinUsar(ROOT, files)
const cambios = churn(ROOT)
const totalLineas = files.reduce((n, f) => n + readFileSync(f, 'utf8').split('\n').length, 0)

const metricas = {
  ficheros: files.length,
  lineas: totalLineas,
  bloquesDuplicados: dup.length,
  lineasDuplicadas: dup.reduce((n, g) => n + g.lineas * (g.sitios.length - 1), 0),
  funcionesLargas: largas.length,
  ficherosMuyAnidados: anidadas.length,
  exportsSinImportar: huerfanos.length,
  depsSinUsar: deps.length,
}

if (JSON_OUT) {
  console.log(JSON.stringify({ metricas, dup, largas, anidadas, huerfanos, deps }, null, 2))
  process.exit(0)
}

// --- Informe -----------------------------------------------------------------

const previo = existsSync(BASELINE) ? JSON.parse(readFileSync(BASELINE, 'utf8')) : null

console.log(`salud de ${relative(process.cwd(), ROOT) || '.'} — ${metricas.ficheros} ficheros, ${metricas.lineas} líneas${CON_TESTS ? '' : ' (tests excluidos, --tests para incluirlos)'}\n`)

if (previo) {
  console.log(`Comparado con la línea base (${previo.fecha}):\n`)
  const filas = Object.entries(metricas).filter(([k]) => !['ficheros', 'lineas'].includes(k))
  for (const [k, v] of filas) {
    const antes = previo.metricas[k] ?? 0
    const d = v - antes
    const señal = d > 0 ? `+${d}` : d < 0 ? String(d) : '='
    console.log(`  ${String(v).padStart(5)}  ${señal.padStart(5)}   ${k}`)
  }
  const peor = filas.filter(([k, v]) => v > (previo.metricas[k] ?? 0))
  console.log(peor.length
    ? `\n  Empeora en ${peor.length} de ${filas.length}. Lo que sube sin motivo es deuda.\n`
    : '\n  Nada empeora respecto a la línea base.\n')
} else {
  console.log('Sin línea base. Ejecuta con --save para fijarla y poder ver la tendencia.\n')
}

const muestra = (titulo, lista, fmt) => {
  if (!lista.length) return
  console.log(`${titulo} (${lista.length}):\n`)
  for (const x of lista.slice(0, TOP)) console.log('  ' + fmt(x))
  if (lista.length > TOP) console.log(`  … y ${lista.length - TOP} más`)
  console.log()
}

muestra('Bloques duplicados', dup, g =>
  `${g.sitios.length}x ${g.lineas} líneas · ${g.sitios.map(s => `${rel(s.file)}:${s.line}`).join('  ')}\n       ${g.muestra.slice(0, 68)}`)
muestra('Funciones largas y con ramas', largas, x =>
  `${String(x.lineas).padStart(4)} líneas · ${String(x.ramas).padStart(3)} ramas  ${rel(x.file)}:${x.line}`)
muestra('Ficheros muy anidados', anidadas, x => `profundidad ${x.profundidad}  ${rel(x.file)}`)
muestra('Exports que nadie importa', huerfanos, x => `${x.nombre.padEnd(28)} ${rel(x.file)}`)
muestra('Dependencias declaradas y sin usar', deps.map(d => ({ d })), x => x.d)
muestra('Ficheros más removidos (90 días)', cambios, x => `${String(x.lineas).padStart(6)} líneas  ${x.file}`)

console.log('Cómo leerlo:\n')
console.log('  La duplicación es la métrica que más sube trabajando con agentes: el')
console.log('  modelo repite patrones en vez de reutilizar lo que ya existe. Un bloque')
console.log('  en dos sitios puede ser casualidad; en cuatro, es una función que falta.')
console.log('  Los exports huérfanos pueden ser API pública: comprueba antes de borrar.')
console.log('  Y un fichero muy removido y muy anidado a la vez es el que más caro te')
console.log('  va a salir: ahí es donde merece la pena el refactor.\n')

if (SAVE) {
  writeFileSync(BASELINE, JSON.stringify({ fecha: new Date().toISOString().slice(0, 10), metricas }, null, 2) + '\n')
  console.log(`línea base guardada en ${relative(process.cwd(), BASELINE)}`)
}
