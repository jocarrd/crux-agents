#!/usr/bin/env node
/**
 * Cuenta los marcadores que delatan un texto generado.
 *
 * No decide: localiza. Si una regla de tres es la figura que el contenido
 * pedía, ahí se queda; el script solo evita que se cuelen treinta sin que
 * nadie las vea.
 */
import { readFileSync } from 'node:fs';

const MARCADORES = [
  {
    id: 'paralelismo-negativo',
    nombre: 'Paralelismo negativo («no es X, es Y»)',
    peso: 3,
    re: [
      /\bno\s+(?:es|son|se\s+trata\s+de|va\s+de|consiste\s+en)\b[^.;!?]{2,60}[:,]\s*(?:es|son|sino)\b/gi,
      // Un contraste al final de la frase —«el historial del shell, no la
      // memoria»— es castellano corriente. Solo cuenta la forma «no es X, es Y».
      /\bno\s+\w+(?:a|e|o|an|en)\b[^.;!?]{0,40},\s*sino\s+(?:que\s+)?\w/gi,
      /\bmás\s+que\s+\w+[^.;!?]{0,40},\s*es\b/gi,
    ],
  },
  {
    id: 'regla-de-tres',
    nombre: 'Regla de tres (tres elementos coordinados)',
    peso: 2,
    re: [
      // sustantivo, sustantivo y sustantivo — sin coma antes, para no
      // marcar los tres últimos de una enumeración más larga
      /(?<![,;] )\b[a-záéíóúñü]{4,}, +[a-záéíóúñü]{4,} +y +[a-záéíóúñü]{4,}\b/gi,
      // verbo, verbo o verbo
      /\b\w{4,}, +\w{4,} +o +\w{4,}\b/gi,
    ],
  },
  {
    id: 'epigrama',
    nombre: 'Titular epigramático (empieza por «Lo que», «Cómo», «Por qué»…)',
    peso: 2,
    soloTitulares: true,
    re: [/^(?:lo\s+que|cómo\s+se|por\s+qué|qué\s+hay|dónde|cuando|así\s+es)\b/i],
  },
  {
    id: 'raya-larga',
    nombre: 'Raya larga (—), por encima de 3 por cada 1.000 palabras',
    peso: 0,
    orientativo: true,
    // En castellano el inciso con raya es correcto. Lo que delata es la
    // densidad, así que solo cuenta el exceso sobre una tasa razonable.
    re: [/—/g],
    exceso: 3,
  },
  {
    id: 'dos-puntos-aforisticos',
    nombre: 'Dos puntos en mitad de frase',
    peso: 0,
    orientativo: true,
    // Solo dentro de una frase ya empezada: un rótulo o una entrada de
    // lista que abre con dos puntos es uso normal, no un tic.
    // Si tras los dos puntos viene una enumeración, es uso normal. El tic
    // es rematar la frase con una sentencia, no abrir una lista.
    re: [/[a-záéíóúñü]{3,}[^.\n]{10,}?[a-záéíóúñü]{3,}: +[a-záéíóúñü][^,.\n]{12,}(?=[.\n])/g],
  },
  {
    id: 'vocabulario',
    nombre: 'Vocabulario recurrente',
    peso: 1,
    re: [
      // «clave» solo como adjetivo: en un texto técnico, la clave suele ser
      // una clave SSH y contarla sería un falso positivo constante.
      /\b(?:es|son|resulta|resultan) clave\b|\b(?:factor|punto|aspecto|elemento|pieza|paso) clave\b|\bclave para\b/gi,
      /\b(?:fundamental|crucial|robusto?a?s?|sólid[oa]s?|potente|riguros[oa]|profundizar|panorama|en última instancia|cabe destacar|es importante señalar|garantizar|optimizar|impulsar)\b/gi,
      /\bno solo\b[^.;!?]{0,60}\bsino también\b/gi,
    ],
  },
  {
    id: 'grandilocuencia',
    nombre: 'Grandilocuencia («lo que hace…», «esto es lo que…»)',
    peso: 2,
    re: [
      // «lo que hace falta» es un giro corriente, no grandilocuencia.
      /\blo que (?!hace falta)(?:hace|separa|distingue) (?:consistente|grande|especial|único|utilizable|de verdad)\b/gi,
      /\b(?:lo que de verdad importa|en el fondo,|al final del día|no es casualidad que)\b/gi,
    ],
  },
];

function analiza(texto, { titulares = [], palabrasTexto = 0 } = {}) {
  const salida = [];
  for (const m of MARCADORES) {
    const fuente = m.soloTitulares ? titulares.join('\n') : texto;
    const casos = [];
    for (const re of m.re) {
      re.lastIndex = 0;
      let x;
      while ((x = re.exec(fuente)) !== null) {
        casos.push(x[0].trim().replace(/\s+/g, ' ').slice(0, 110));
        if (x[0].length === 0) re.lastIndex += 1;
      }
    }
    let n = casos.length;
    if (m.exceso) {
      const permitidas = Math.round((palabrasTexto / 1000) * m.exceso);
      n = Math.max(0, n - permitidas);
    }
    salida.push({ ...m, n, casos });
  }
  return salida;
}

function linea(original, fragmento) {
  const aguja = fragmento.slice(0, 32).trim();
  const i = original.indexOf(aguja);
  return i < 0 ? '?' : original.slice(0, i).split('\n').length;
}

const [, , orden, ...resto] = process.argv;
if (!orden || !['revisar', 'detalle'].includes(orden)) {
  console.log('uso: redaccion.mjs revisar <fichero…> | --texto "…"');
  console.log('     redaccion.mjs detalle <fichero>');
  process.exit(1);
}

/**
 * Fuera las citas y el código: un texto que enseña ejemplos de mala escritura
 * los tiene escritos, y contarlos como suyos convierte al revisor en el peor
 * alumno de su propia lección.
 */
function soloProsa(md) {
  return md
    .replace(/^---\n[\s\S]*?\n---\n/, '')  // cabecera YAML: no es prosa del autor
    .replace(/```[\s\S]*?```/g, '')      // bloques de código
    .replace(/^\s*>.*$/gm, '')           // citas
    .replace(/«[^»]*»/g, '')             // lo entrecomillado se cita, no se firma
    .replace(/`[^`]*`/g, '')             // código en línea
    .split('\n')
    .filter((l) => !/^\s*[-*·]\s*`/.test(l))  // listas de términos entrecomillados
    .join('\n');
}

let texto = '';
let etiqueta = '';
if (resto[0] === '--texto') {
  texto = resto.slice(1).join(' ');
  etiqueta = '(texto suelto)';
} else {
  texto = resto.map((f) => readFileSync(f, 'utf8')).join('\n');
  etiqueta = resto.join(', ');
}
const crudo = texto;
texto = soloProsa(texto);

// Titulares: líneas de markdown con # o líneas cortas sin punto final.
const titulares = crudo
  .split('\n')
  .map((l) => l.trim())
  .filter((l) => /^#{1,6}\s/.test(l))
  .map((l) => l.replace(/^#{1,6}\s+/, ''));

const palabras = texto.split(/\s+/).filter(Boolean).length;
const res = analiza(texto, { titulares, palabrasTexto: palabras });
const carga = res.reduce((a, m) => a + m.n * m.peso, 0);
const por1000 = palabras ? (carga / palabras) * 1000 : 0;

console.log(`\n${etiqueta} · ${palabras} palabras · ${titulares.length} titulares\n`);
for (const m of res) {
  const marca = m.n === 0 ? '  ' : m.orientativo ? '··' : m.peso >= 2 ? '🔴' : '🟡';
  const cola = m.orientativo ? '  (orientativo, no puntúa)' : '';
  console.log(`${marca} ${String(m.n).padStart(3)}  ${m.nombre}${cola}`);
  if (orden === 'detalle' && m.n) {
    for (const c of m.casos.slice(0, 12)) console.log(`         L${linea(texto, c)}  ${c}`);
    if (m.casos.length > 12) console.log(`         … y ${m.casos.length - 12} más`);
  }
}
const veredicto = por1000 < 4 ? 'suena a persona' : por1000 < 9 ? 'revisable' : 'suena a máquina';
console.log(`\ncarga ${carga} · ${por1000.toFixed(1)} por cada 1.000 palabras — ${veredicto}`);
console.log('\nSolo puntúan los cinco marcadores fiables. La raya larga y los dos puntos se');
console.log('informan porque una expresión regular no distingue un remate de una explicación.\n');
process.exit(por1000 >= 9 ? 1 : 0);
