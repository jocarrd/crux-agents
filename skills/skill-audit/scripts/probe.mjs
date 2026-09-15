#!/usr/bin/env node
// Qué skill se activaría ante una frase, y por cuánto gana.
//
//   probe.mjs "la frase con la que pedirías el trabajo"
//   probe.mjs --casos [fichero]        pasa un fichero de casos y reporta fallos
//
// El resto del sistema se verifica: la estructura con doctor, el cambio con la
// puerta, el idioma del commit con un hook. La activación era lo único que se
// confiaba, y es lo que decide si todo lo demás llega a usarse.
//
// Esto NO predice lo que hará el agente. Puntúa el solape de vocabulario entre
// la frase y cada descripción, ponderando las palabras raras del catálogo. Sirve
// para lo que hace falta: comparar dos redacciones y ver si una regresión ha
// apagado una skill. Un empate aquí es una señal fiable de que dos
// descripciones no se distinguen; un ganador no garantiza que gane de verdad.

import { readFileSync, existsSync, readdirSync, statSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const VACIAS = new Set(`de la el en y a los las del un una para con por que se su al lo como más o pero sus
le ya esto si porque esta entre muy sin sobre también me hasta hay donde quien desde todo nos durante todos
uno les ni contra otros ese eso ante ellos esa the and for with when this that from your usa use usar invoca
cuando`.split(/\s+/))

// Las palabras se comparan tal cual, sin recortar terminaciones. Se probaron
// dos stemmers —uno de sufijos verbales y otro solo de plurales— y los dos
// EMPEORARON la medida sobre los mismos 24 casos: de 2 fallos a 3, con
// `oauth-reauthorize` ganando una frase de cierre de sesión. Fusionan raíces que
// no son la misma y crean colisiones falsas, que es peor que el problema que
// resolvían. Si se reintenta, mídase contra `casos/activacion.tsv` antes.
//
// El precio conocido: «merece» y «merecen» cuentan como palabras distintas.

function palabras(s) {
  return (s || '')
    .toLowerCase()
    .replace(/[^\p{L}\p{N}\s-]/gu, ' ')
    .split(/\s+/)
    .filter(w => w.length > 3 && !VACIAS.has(w))
}

function descripcion(texto) {
  const m = texto.match(/^description:\s*([\s\S]*?)(?=\n[a-z_-]+:|\n---)/m)
  return m ? m[1].replace(/\s+/g, ' ').trim() : ''
}

// El catálogo que ve el agente, no el que hay en los repos: lo que importa es
// contra qué compite de verdad.
function catalogo() {
  const dir = process.env.CLAUDE_SKILLS_DIR || join(process.env.HOME, '.claude', 'skills')
  const salida = new Map()
  if (!existsSync(dir)) return salida
  for (const n of readdirSync(dir)) {
    const f = join(dir, n, 'SKILL.md')
    try {
      if (statSync(f).isFile()) salida.set(n, new Set(palabras(descripcion(readFileSync(f, 'utf8')))))
    } catch {
      // enlace roto: lo reporta `crux doctor --machine`
    }
  }
  return salida
}

const SKILLS = catalogo()
if (!SKILLS.size) {
  console.error('no hay skills instaladas que consultar')
  process.exit(1)
}

// Una palabra que sale en cuarenta descripciones no distingue nada; una que sale
// en una, lo distingue todo. Con `log(1 + N/df)` eso no se cumplía: lo que está
// en todas seguía pesando, y el listado se llenaba de skills que solo
// compartían una palabra de plantilla. `log(N/df)` lleva ese caso a cero.
const enCuantas = new Map()
for (const ws of SKILLS.values()) for (const w of ws) enCuantas.set(w, (enCuantas.get(w) || 0) + 1)
const N = SKILLS.size

function puntuar(frase) {
  const q = new Set(palabras(frase))
  const r = []
  for (const [nombre, ws] of SKILLS) {
    let s = 0
    for (const w of q) if (ws.has(w)) s += Math.log(N / enCuantas.get(w))
    if (s > 0) r.push({ nombre, punto: +s.toFixed(2) })
  }
  return r.sort((a, b) => b.punto - a.punto)
}

// Por debajo de esto dos descripciones no se distinguen: cuál gane depende del
// azar de una palabra, no de lo que dicen. Es una fracción del líder y no un
// valor absoluto, porque la puntuación crece con el número de palabras de la
// frase: 0,5 era mucho en «revisar la propuesta» y casi nada en una frase de
// doce palabras, y los casos del fichero tienen las dos longitudes.
const MARGEN_MINIMO = 0.15

function margenRelativo(r) {
  if (r.length < 2 || !r[0].punto) return 1
  return (r[0].punto - r[1].punto) / r[0].punto
}

function informe(frase) {
  const r = puntuar(frase)
  console.log(`\n"${frase}"\n`)
  if (!r.length) {
    console.log('  ninguna skill comparte vocabulario con esa frase')
    return
  }
  for (const { nombre, punto } of r.slice(0, 5)) console.log(`  ${String(punto).padStart(6)}  ${nombre}`)
  if (r.length > 1) {
    const m = margenRelativo(r)
    console.log(`\n  margen entre la 1ª y la 2ª: ${(m * 100).toFixed(0)}%${m < MARGEN_MINIMO ? '  — no se distinguen' : ''}`)
  }
}

const args = process.argv.slice(2)

if (args[0] === '--casos') {
  const fichero = args[1] || join(dirname(fileURLToPath(import.meta.url)), '..', 'casos', 'activacion.tsv')
  if (!existsSync(fichero)) {
    console.error(`no existe el fichero de casos: ${fichero}`)
    process.exit(2)
  }
  let total = 0, fallos = 0, estrechos = 0
  const lineas = readFileSync(fichero, 'utf8').split('\n')
  for (const [i, linea] of lineas.entries()) {
    if (!linea.trim() || linea.startsWith('#')) continue
    const [esperada, ...resto] = linea.split('\t')
    const frase = resto.join(' ').trim()
    // Un tabulador convertido en espacios es el error natural al editar esto a
    // mano, y saltárselo en silencio deja un fichero de casos que no prueba
    // nada y sigue saliendo en verde.
    if (!frase) {
      console.error(`${fichero}:${i + 1} sin tabulador entre la skill y la frase`)
      process.exit(2)
    }
    total++
    const r = puntuar(frase)
    const puesto = r.findIndex(x => x.nombre === esperada) + 1
    const margen = margenRelativo(r)

    if (puesto !== 1) {
      fallos++
      console.log(`FALLA  esperaba ${esperada}, gana ${r[0]?.nombre || '(ninguna)'}${puesto ? ` — ${esperada} va en el puesto ${puesto}` : ` — ${esperada} no puntúa`}`)
      console.log(`       "${frase}"`)
    } else if (margen < MARGEN_MINIMO) {
      estrechos++
      console.log(`JUSTA  ${esperada} gana por ${(margen * 100).toFixed(0)}% a ${r[1].nombre} — no se distinguen`)
      console.log(`       "${frase}"`)
    }
  }
  if (!total) {
    console.error(`${fichero} no tiene ni un caso`)
    process.exit(2)
  }
  console.log(`\n${total} casos · ${fallos} fallan · ${estrechos} ganan sin distinguirse`)
  process.exit(fallos ? 1 : 0)
}

if (!args.length) {
  console.error('uso: probe.mjs "frase"   |   probe.mjs --casos [fichero]')
  process.exit(2)
}

informe(args.join(' '))
