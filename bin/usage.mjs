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

// Los scripts de una skill son la otra cara de su uso: quien sigue el
// procedimiento a mano los ejecuta sin llamar a la skill por su nombre, y
// contando solo las llamadas esa skill sale como muerta. Pasó con la puerta de
// calidad: cero invocaciones mientras se pasaba en cuatro propuestas seguidas.
function scriptsDelCatalogo() {
  const out = new Map()
  const kernel = join(CRUX_HOME, 'skills')
  if (!existsSync(kernel)) return out
  for (const skill of readdirSync(kernel)) {
    const dir = join(kernel, skill, 'scripts')
    if (!existsSync(dir)) continue
    for (const s of readdirSync(dir)) out.set(s, skill)
  }
  return out
}

// Un nombre de script aparece en muchos comandos que no lo ejecutan: leerlo,
// copiarlo, buscar dentro. Se descarta cuando lo precede un verbo de lectura.
const VERBO_DE_LECTURA = /\b(cat|sed|awk|grep|head|tail|less|ls|wc|chmod|cp|mv|rm|find|diff|git|shellcheck|vim|nano)\s+(-\S+\s+)*\S*$/

function invocaciones(desde) {
  const cuenta = new Map()
  const porScript = new Map()
  const scripts = scriptsDelCatalogo()
  let ficheros = 0
  if (!existsSync(TRANSCRIPTS)) return { cuenta, porScript, ficheros }

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
      if (!scripts.size) continue
      for (const m of texto.matchAll(/"name"\s*:\s*"Bash"\s*,\s*"input"\s*:\s*\{[^}]*?"command"\s*:\s*"((?:[^"\\]|\\.)*)"/g)) {
        const cmd = m[1]
        for (const [script, skill] of scripts) {
          for (const h of cmd.matchAll(new RegExp(script.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'g'))) {
            if (VERBO_DE_LECTURA.test(cmd.slice(0, h.index))) continue
            porScript.set(skill, (porScript.get(skill) || 0) + 1)
          }
        }
      }
    }
  }
  return { cuenta, porScript, ficheros }
}

const desde = Date.now() - days * 24 * 3600 * 1000
const cat = catalogo()
const { cuenta, porScript, ficheros } = invocaciones(desde)

console.log(`uso de skills — últimos ${days} días · ${ficheros} sesiones revisadas\n`)

if (!ficheros) {
  console.log('No hay transcripciones en el periodo. Sin datos, no sin uso.\n')
  process.exit(0)
}
if (!cuenta.size && !porScript.size) {
  console.log('Ninguna invocación encontrada. Puede que el formato de las')
  console.log('transcripciones haya cambiado: compruébalo antes de concluir')
  console.log('que no se usa ninguna skill.\n')
  process.exit(0)
}

const nombres = new Set([...cuenta.keys(), ...porScript.keys()])
const usadas = [...nombres]
  .map(n => [n, cuenta.get(n) || 0, porScript.get(n) || 0])
  .sort((a, b) => (b[1] + b[2]) - (a[1] + a[2]))

console.log('Usadas:\n')
console.log("  llamada  script  origen           skill")
for (const [nombre, n, s] of usadas) {
  const origen = cat.get(nombre) || '(de otra fuente)'
  console.log(`  ${String(n).padStart(7)}  ${String(s || '').padStart(6)}  ${origen.padEnd(16)} ${nombre}`)
}
console.log('\n  "llamada" es la skill invocada por su nombre. "script" es el rastro de')
console.log('  sus scripts en comandos: el procedimiento seguido a mano. No se suman —')
console.log('  no son la misma unidad, y el segundo es una cota superior porque')
console.log('  incluye las ejecuciones desde tests.')

const huerfanas = usadas.filter(([n]) => !cat.has(n)).map(([n]) => n)
if (huerfanas.length) {
  console.log('\nInvocadas y ausentes de este catálogo:\n')
  for (const n of huerfanas) console.log(`  ${n}`)
  console.log('\n  Probablemente vengan del propio agente o de un plugin, y entonces no')
  console.log('  hay nada que arreglar: crux solo conoce sus dos catálogos. Si en')
  console.log('  cambio es un nombre tuyo que se renombró, corrige la referencia.')
}

const nunca = [...cat.entries()].filter(([n]) => !cuenta.has(n) && !porScript.has(n))
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
