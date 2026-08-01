#!/usr/bin/env node
// crux usage — qué skills se usan de verdad.
//
//   crux usage [--days N] [--all]
//
// Un catálogo que solo crece acaba estorbando al descubrimiento: cuantas más
// skills hay, peor se elige entre ellas. Esto mide el uso real contra el
// catálogo instalado y separa lo vivo de lo muerto.
//
// La fuente son las transcripciones locales del agente. Es un formato interno
// y puede cambiar; si un día deja de encontrar invocaciones, lo dice en vez de
// reportar cero como si fuera un dato.

import { readFileSync, readdirSync, existsSync, statSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { homedir } from 'node:os'

const HOME = homedir()
// La raíz de proyectos no se asume: sale de la config de la máquina o del sitio
// donde está instalado el kernel, que siempre vive dentro de ella.
function raizProyectos() {
  if (process.env.CRUX_PROJECTS_DIR) return process.env.CRUX_PROJECTS_DIR
  try {
    const cfg = readFileSync(join(homedir(), '.crux', 'config'), 'utf8')
    const m = cfg.match(/^CRUX_PROJECTS_DIR="?([^"\n]+)"?/m)
    if (m) return m[1]
    const k = cfg.match(/^CRUX_HOME="?([^"\n]+)"?/m)
    if (k) return dirname(k[1])
  } catch {}
  if (process.env.CRUX_HOME) return dirname(process.env.CRUX_HOME)
  return join(homedir(), 'Proyectos')
}

const PROYECTOS = raizProyectos()
const CRUX_HOME = process.env.CRUX_HOME || join(PROYECTOS, 'crux')
const TRANSCRIPTS = process.env.CRUX_TRANSCRIPTS || join(HOME, '.claude', 'projects')

const args = process.argv.slice(2)
const days = Number((args.find(a => a.startsWith('--days')) || '').split('=')[1] || 90)
const showAll = args.includes('--all')

function catalogo() {
  const out = new Map()
  const kernel = join(CRUX_HOME, 'skills')
  if (existsSync(kernel)) {
    for (const n of readdirSync(kernel)) {
      if (statSync(join(kernel, n)).isDirectory()) out.set(n, 'kernel')
    }
  }
  const proyectos = PROYECTOS
  if (existsSync(proyectos)) {
    for (const p of readdirSync(proyectos)) {
      const dir = join(proyectos, p)
      if (!statSync(dir).isDirectory()) continue
      for (const sub of readdirSync(dir)) {
        if (!sub.endsWith('-docs')) continue
        const skills = join(dir, sub, '.claude', 'skills', 'project')
        if (!existsSync(skills)) continue
        for (const n of readdirSync(skills)) {
          if (statSync(join(skills, n)).isDirectory()) out.set(n, sub.replace('-docs', ''))
        }
      }
    }
  }
  return out
}

function invocaciones(desde) {
  const cuenta = new Map()
  let ficheros = 0
  if (!existsSync(TRANSCRIPTS)) return { cuenta, ficheros }

  for (const proyecto of readdirSync(TRANSCRIPTS)) {
    const dir = join(TRANSCRIPTS, proyecto)
    if (!statSync(dir).isDirectory()) continue
    for (const f of readdirSync(dir)) {
      if (!f.endsWith('.jsonl')) continue
      const full = join(dir, f)
      if (statSync(full).mtimeMs < desde) continue
      ficheros++
      const texto = readFileSync(full, 'utf8')
      for (const m of texto.matchAll(/"name"\s*:\s*"Skill"\s*,\s*"input"\s*:\s*\{\s*"skill"\s*:\s*"([^"]+)"/g)) {
        cuenta.set(m[1], (cuenta.get(m[1]) || 0) + 1)
      }
    }
  }
  return { cuenta, ficheros }
}

const desde = Date.now() - days * 24 * 3600 * 1000
const cat = catalogo()
const { cuenta, ficheros } = invocaciones(desde)

console.log(`uso de skills — últimos ${days} días · ${ficheros} sesiones revisadas\n`)

if (!ficheros) {
  console.log('No hay transcripciones en el periodo. Sin datos, no sin uso.\n')
  process.exit(0)
}
if (!cuenta.size) {
  console.log('Ninguna invocación encontrada. Puede que el formato de las')
  console.log('transcripciones haya cambiado: compruébalo antes de concluir')
  console.log('que no se usa ninguna skill.\n')
  process.exit(0)
}

const usadas = [...cuenta.entries()].sort((a, b) => b[1] - a[1])

console.log('Usadas:\n')
console.log('  veces  origen        skill')
for (const [nombre, n] of usadas) {
  const origen = cat.get(nombre) || '(no instalada)'
  console.log(`  ${String(n).padStart(5)}  ${origen.padEnd(13)} ${nombre}`)
}

const huerfanas = usadas.filter(([n]) => !cat.has(n)).map(([n]) => n)
if (huerfanas.length) {
  console.log('\nInvocadas pero ausentes del catálogo:\n')
  for (const n of huerfanas) console.log(`  ${n}`)
  console.log('\n  O se renombraron, o son de otra fuente. Si el nombre viejo se sigue')
  console.log('  invocando, merece la pena dejar el alias o corregir la referencia.')
}

const nunca = [...cat.entries()].filter(([n]) => !cuenta.has(n))
if (nunca.length) {
  console.log(`\nSin usar en el periodo (${nunca.length} de ${cat.size}):\n`)
  const porOrigen = new Map()
  for (const [n, o] of nunca) porOrigen.set(o, [...(porOrigen.get(o) || []), n])
  for (const [origen, lista] of porOrigen) {
    console.log(`  ${origen}: ${showAll ? lista.join(', ') : lista.slice(0, 8).join(', ') + (lista.length > 8 ? `, +${lista.length - 8}` : '')}`)
  }
  console.log('\n  No es una lista de borrado. Una skill de incidencias que no se ha')
  console.log('  usado es una buena noticia; una recién creada aún no ha tenido')
  console.log('  ocasión. Lo que hay que mirar es la que existe hace meses, cubre')
  console.log('  algo frecuente y aun así nadie invoca: casi siempre es que su')
  console.log('  descripción no se activa cuando debería.')
}
console.log()
