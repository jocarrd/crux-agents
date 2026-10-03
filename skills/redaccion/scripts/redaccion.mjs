#!/usr/bin/env node
/**
 * Counts the markers that give away a generated text. The detection regexes
 * target Spanish prose and stay in Spanish.
 *
 * It does not decide: it locates. If a rule of three is the figure the content
 * called for, it stays; the script only keeps thirty from slipping in unseen.
 */
import { readFileSync } from 'node:fs';

const MARKERS = [
  {
    id: 'paralelismo-negativo',
    name: 'Negative parallelism ("no es X, es Y")',
    weight: 3,
    re: [
      /\bno\s+(?:es|son|se\s+trata\s+de|va\s+de|consiste\s+en)\b[^.;!?]{2,60}[:,]\s*(?:es|son|sino)\b/gi,
      // A contrast at the end of the sentence ("el historial del shell, no la
      // memoria") is ordinary Spanish. Only the "no es X, es Y" form counts.
      /\bno\s+\w+(?:a|e|o|an|en)\b[^.;!?]{0,40},\s*sino\s+(?:que\s+)?\w/gi,
      /\bmás\s+que\s+\w+[^.;!?]{0,40},\s*es\b/gi,
    ],
  },
  {
    id: 'regla-de-tres',
    name: 'Rule of three (three coordinated items)',
    weight: 2,
    re: [
      // noun, noun y noun: no comma before, so as not to flag the last
      // three of a longer enumeration
      /(?<![,;] )\b[a-záéíóúñü]{4,}, +[a-záéíóúñü]{4,} +y +[a-záéíóúñü]{4,}\b/gi,
      // verb, verb o verb
      /\b\w{4,}, +\w{4,} +o +\w{4,}\b/gi,
    ],
  },
  {
    id: 'epigrama',
    name: 'Epigrammatic headline (starts with "Lo que", "Cómo", "Por qué"...)',
    weight: 2,
    headingsOnly: true,
    re: [/^(?:lo\s+que|cómo\s+se|por\s+qué|qué\s+hay|dónde|cuando|así\s+es)\b/i],
  },
  {
    id: 'raya-larga',
    name: 'Em dash (—), above 3 per 1,000 words',
    weight: 0,
    advisory: true,
    // In Spanish the dash aside is correct. What gives it away is the
    // density, so only the excess over a reasonable rate counts.
    re: [/—/g],
    excess: 3,
  },
  {
    id: 'dos-puntos-aforisticos',
    name: 'Colon in mid-sentence',
    weight: 0,
    advisory: true,
    // Only inside an already started sentence: a label or list item that
    // opens with a colon is normal usage, not a tic.
    // If an enumeration follows the colon, it is normal usage. The tic is
    // closing the sentence with a maxim, not opening a list.
    re: [/[a-záéíóúñü]{3,}[^.\n]{10,}?[a-záéíóúñü]{3,}: +[a-záéíóúñü][^,.\n]{12,}(?=[.\n])/g],
  },
  {
    id: 'vocabulario',
    name: 'Recurring vocabulary',
    weight: 1,
    re: [
      // "clave" only as an adjective: in a technical text, the clave is
      // usually an SSH key and counting it would be a constant false positive.
      /\b(?:es|son|resulta|resultan) clave\b|\b(?:factor|punto|aspecto|elemento|pieza|paso) clave\b|\bclave para\b/gi,
      /\b(?:fundamental|crucial|robusto?a?s?|sólid[oa]s?|potente|riguros[oa]|profundizar|panorama|en última instancia|cabe destacar|es importante señalar|garantizar|optimizar|impulsar)\b/gi,
      /\bno solo\b[^.;!?]{0,60}\bsino también\b/gi,
    ],
  },
  {
    id: 'grandilocuencia',
    name: 'Grandiloquence ("lo que hace...", "esto es lo que...")',
    weight: 2,
    re: [
      // "lo que hace falta" is an ordinary phrase, not grandiloquence.
      /\blo que (?!hace falta)(?:hace|separa|distingue) (?:consistente|grande|especial|único|utilizable|de verdad)\b/gi,
      /\b(?:lo que de verdad importa|en el fondo,|al final del día|no es casualidad que)\b/gi,
    ],
  },
];

function analyze(text, { headings = [], textWords = 0 } = {}) {
  const output = [];
  for (const m of MARKERS) {
    const source = m.headingsOnly ? headings.join('\n') : text;
    const cases = [];
    for (const re of m.re) {
      re.lastIndex = 0;
      let x;
      while ((x = re.exec(source)) !== null) {
        cases.push(x[0].trim().replace(/\s+/g, ' ').slice(0, 110));
        if (x[0].length === 0) re.lastIndex += 1;
      }
    }
    let n = cases.length;
    if (m.excess) {
      const allowed = Math.round((textWords / 1000) * m.excess);
      n = Math.max(0, n - allowed);
    }
    output.push({ ...m, n, cases });
  }
  return output;
}

function line(original, fragment) {
  const needle = fragment.slice(0, 32).trim();
  const i = original.indexOf(needle);
  return i < 0 ? '?' : original.slice(0, i).split('\n').length;
}

const [, , order, ...rest] = process.argv;
const ALIASES = { check: 'revisar', detail: 'detalle' };
const command = ALIASES[order] || order;
if (!command || !['revisar', 'detalle'].includes(command)) {
  console.log('usage: redaccion.mjs check <file...> | --text "..."');
  console.log('       redaccion.mjs detail <file>');
  console.log('(revisar / detalle / --texto still work)');
  process.exit(1);
}

/**
 * Strip quotes and code: a text that teaches examples of bad writing has them
 * written out, and counting them as its own turns the reviewer into the worst
 * student of its own lesson.
 */
function proseOnly(md) {
  return md
    .replace(/^---\n[\s\S]*?\n---\n/, '')  // YAML header: not the author's prose
    .replace(/```[\s\S]*?```/g, '')      // code blocks
    .replace(/^\s*>.*$/gm, '')           // quotes
    .replace(/«[^»]*»/g, '')             // quoted text is cited, not signed
    .replace(/`[^`]*`/g, '')             // inline code
    .split('\n')
    .filter((l) => !/^\s*[-*·]\s*`/.test(l))  // lists of quoted terms
    .join('\n');
}

let text = '';
let label = '';
if (rest[0] === '--texto' || rest[0] === '--text') {
  text = rest.slice(1).join(' ');
  label = '(loose text)';
} else {
  text = rest.map((f) => readFileSync(f, 'utf8')).join('\n');
  label = rest.join(', ');
}
const raw = text;
text = proseOnly(text);

// Headlines: markdown lines with # or short lines without a final period.
const headings = raw
  .split('\n')
  .map((l) => l.trim())
  .filter((l) => /^#{1,6}\s/.test(l))
  .map((l) => l.replace(/^#{1,6}\s+/, ''));

const words = text.split(/\s+/).filter(Boolean).length;
const res = analyze(text, { headings, textWords: words });
const load = res.reduce((a, m) => a + m.n * m.weight, 0);
const per1000 = words ? (load / words) * 1000 : 0;

console.log(`\n${label} · ${words} words · ${headings.length} headlines\n`);
for (const m of res) {
  const marker = m.n === 0 ? '  ' : m.advisory ? '··' : m.weight >= 2 ? '🔴' : '🟡';
  const tail = m.advisory ? '  (advisory, not scored)' : '';
  console.log(`${marker} ${String(m.n).padStart(3)}  ${m.name}${tail}`);
  if (command === 'detalle' && m.n) {
    for (const c of m.cases.slice(0, 12)) console.log(`         L${line(text, c)}  ${c}`);
    if (m.cases.length > 12) console.log(`         ... and ${m.cases.length - 12} more`);
  }
}
const verdict = per1000 < 4 ? 'sounds human' : per1000 < 9 ? 'worth a review' : 'sounds like a machine';
console.log(`\nload ${load} · ${per1000.toFixed(1)} per 1,000 words — ${verdict}`);
console.log('\nOnly the five reliable markers are scored. The em dash and the colons are');
console.log('reported because a regex cannot tell a closing line from an explanation.\n');
process.exit(per1000 >= 9 ? 1 : 0);
