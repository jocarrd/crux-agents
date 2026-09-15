#!/usr/bin/env node
// Revisa las descripciones de un catálogo de skills: que existan, que estén
// bien formadas y que digan cuándo usarse.
//
//   check-skill-description.mjs <directorio> [idioma]
//
// La descripción es lo que decide si una skill se activa. Todo lo demás del
// sistema se verifica —la estructura con doctor, el cambio con la puerta, el
// idioma del commit con un hook— y esto era la excepción: se confiaba.
//
// Vivía dentro del bloque 10 de `doctor`, en bash, y por eso solo alcanzaba a
// las skills del proyecto. Las del kernel —que están en todas las sesiones y
// son las que más compiten por la atención— no las miraba nadie. Sacarlo aquí
// es lo que permite pasar la misma vara por los dos catálogos.
//
// Cada hallazgo sale con su severidad delante: `error` si la skill no se puede
// cargar, `aviso` si se carga pero no se activará cuando toque.

import { readFileSync, existsSync, readdirSync, statSync } from 'node:fs'
import { join, basename, dirname } from 'node:path'

const raiz = process.argv[2]
const idioma = process.argv[3] || 'es'
if (!raiz) {
  console.error('uso: check-skill-description.mjs <directorio de skills> [idioma]')
  process.exit(2)
}
if (!existsSync(raiz)) process.exit(0)

// Un verbo de uso es lo que convierte una descripción en un disparador. Sin él
// la skill queda descrita pero no dice en qué situación aparece, y entonces
// existe sin llegar nunca.
const DISPARA = /\b(usa|use|úsala|usala|usar|invoca|cuando|when)\b/i

const EN = /\b(the|when|this|with|your|after|before|that|from|which)\b/gi
const ES = /\b(cuando|para|que|con|desde|antes|después|del|las|los|una)\b/gi

export function descripcionDe(texto) {
  // Solo el frontmatter: si se lee de más, el cuerpo de la skill contamina la
  // comprobación y esto no detecta nada nunca.
  const lineas = texto.split('\n')
  if (lineas[0].trim() !== '---') return null
  const salida = []
  let dentro = false
  for (let i = 1; i < lineas.length; i++) {
    const l = lineas[i]
    if (l.trim() === '---') break
    if (/^description:/.test(l)) {
      dentro = true
      salida.push(l.replace(/^description:\s*/, ''))
      continue
    }
    if (dentro && /^[a-z_-]+:/.test(l)) break
    if (dentro) salida.push(l)
  }
  return salida.join(' ').replace(/\s+/g, ' ').trim()
}

function skillsDe(dir) {
  const salida = []
  const visitar = (d, profundidad) => {
    if (profundidad > 3) return
    for (const entrada of readdirSync(d)) {
      const p = join(d, entrada)
      let st
      try {
        st = statSync(p)
      } catch {
        continue // enlace roto: lo reporta `doctor --machine`
      }
      if (st.isDirectory()) visitar(p, profundidad + 1)
      else if (entrada === 'SKILL.md') salida.push(p)
    }
  }
  visitar(dir, 0)
  return salida.sort()
}

const hallazgos = []

for (const ruta of skillsDe(raiz)) {
  const nombre = basename(dirname(ruta))
  const texto = readFileSync(ruta, 'utf8')

  if (texto.split('\n')[0].trim() !== '---') {
    hallazgos.push(`error skill sin frontmatter: ${nombre}`)
    continue
  }
  // Sin la línea de cierre el frontmatter no es YAML válido y el agente carga
  // la skill entera como cuerpo, o no la carga.
  if ((texto.match(/^---$/gm) || []).length < 2) {
    hallazgos.push(`error skill con el frontmatter sin cerrar: ${nombre}`)
    continue
  }
  if (!/^name:/m.test(texto)) hallazgos.push(`error skill sin 'name' en el frontmatter: ${nombre}`)
  if (!/^description:/m.test(texto)) {
    hallazgos.push(`error skill sin 'description' en el frontmatter: ${nombre}`)
    continue
  }
  if (!new RegExp(`^name: *${nombre}$`, 'm').test(texto)) {
    hallazgos.push(`aviso skill '${nombre}': el 'name' del frontmatter no coincide con el directorio`)
  }

  const desc = descripcionDe(texto) || ''
  if (!DISPARA.test(desc)) {
    hallazgos.push(`aviso skill '${nombre}': la descripción no dice cuándo usarla — no se activará sola`)
  }

  // La descripción decide la activación, así que tiene que estar en el idioma
  // en que se pide el trabajo. Una mezcla activa peor justo donde más duele.
  if (idioma === 'es') {
    const en = (desc.match(EN) || []).length
    const es = (desc.match(ES) || []).length
    if (en > es) {
      hallazgos.push(`aviso skill '${nombre}': la descripción parece estar en inglés y el catálogo declara español`)
    }
  }
}

for (const h of hallazgos) console.log(h)
process.exit(0)
