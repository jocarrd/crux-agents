#!/usr/bin/env node
// El registro de una tarea: un markdown con cabecera, uno por tarea.
//
//   node lib/task.mjs <operación> --file <ruta> [opciones]
//
// Lo escriben los comandos, no el agente a mano: una casilla o un estado que
// dependen de que alguien se acuerde de editar un fichero acaban mintiendo, y
// un registro que miente es peor que no tenerlo. Ver ADR-012.
//
// Un solo fichero como fuente de verdad. Su réplica en el docs repo, para que
// la tarea siga en otra máquina, la escribe siempre lib/task-sync.mjs a partir
// de él, nunca a mano. Ver ADR-016.

import fs from "node:fs";
import path from "node:path";
import { apuntarBorrado, publicarEnSegundoPlano } from "./task-sync.mjs";

export const ESTADOS = ["open", "planned", "in-progress", "verified", "proposed", "merged", "deployed", "closed"];

// El orden de las secciones es el de la vida de la tarea: lo que se quiere, lo
// que se hace, lo que se decide por el camino y lo que se comprobó.
export const SECCIONES = [
  ["Objetivo", "Una frase: qué se quiere conseguir y por qué."],
  ["Alcance", "Qué entra y qué se queda fuera."],
  ["Plan", "Solo si la tarea lo necesita: qué cambia, la traza, qué se rompe, alternativas y dudas."],
  ["Pasos", ""],
  ["Siguiente paso", ""],
  ["Desviaciones y decisiones", "Lo que salió distinto del plan y lo que se decidió con el código delante."],
  ["Verificación", ""],
  ["Cierre", ""],
];

const ahora = () => {
  const d = new Date();
  const p = (n) => String(n).padStart(2, "0");
  // Con segundos: la fecha de creación identifica una tarea archivada, y dos
  // tareas con el mismo nombre creadas en el mismo minuto se confundían.
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
};

// --- Lectura y escritura --------------------------------------------------------

export function parse(texto) {
  const m = texto.match(/^---\n([\s\S]*?)\n---\n?/);
  if (!m) throw new Error("el registro no tiene cabecera");
  const meta = {};
  for (const linea of m[1].split("\n")) {
    // Cualquier clave, no solo las minusculas de una palabra: las demas se
    // borraban en la primera escritura automatica.
    const kv = linea.match(/^([A-Za-z][A-Za-z0-9_-]*):\s*(.*)$/);
    if (!kv) continue;
    const v = kv[2].trim();
    meta[kv[1]] = v.startsWith("[") ? v.slice(1, -1).split(",").map((s) => s.trim()).filter(Boolean) : v;
  }
  const secciones = [];
  // Lo que va entre la cabecera y el primer `## ` tambien es del documento:
  // un parrafo de contexto escrito a mano desaparecia al reescribir.
  const entrada = [];
  let actual = null;
  // Un `## ` dentro de un bloque de codigo es texto, no un titulo. Partirlo
  // ahi metia lo siguiente dentro del bloque y dejaba el resto colgando de una
  // seccion fantasma, y el cuerpo de la propuesta salia truncado.
  let enCodigo = false;
  for (const linea of texto.slice(m[0].length).split("\n")) {
    if (/^\s*(```|~~~)/.test(linea)) enCodigo = !enCodigo;
    const h = enCodigo ? null : linea.match(/^## (.+)$/);
    if (h) {
      actual = { titulo: h[1].trim(), lineas: [] };
      secciones.push(actual);
    } else if (actual) {
      actual.lineas.push(linea);
    } else {
      entrada.push(linea);
    }
  }
  while (entrada.length && entrada[entrada.length - 1].trim() === "") entrada.pop();
  while (entrada.length && entrada[0].trim() === "") entrada.shift();
  return { meta, secciones, entrada };
}

export function render({ meta, secciones, entrada = [] }) {
  const orden = ["task", "project", "status", "repos", "workspaces", "branches", "created", "updated", "pr"];
  const claves = [...orden.filter((k) => k in meta), ...Object.keys(meta).filter((k) => !orden.includes(k))];
  const cab = claves
    .map((k) => `${k}: ${Array.isArray(meta[k]) ? `[${meta[k].join(", ")}]` : meta[k]}`)
    .join("\n");
  const cuerpo = secciones
    .map((s) => {
      const lineas = [...s.lineas];
      while (lineas.length && lineas[lineas.length - 1].trim() === "") lineas.pop();
      while (lineas.length && lineas[0].trim() === "") lineas.shift();
      return `## ${s.titulo}\n\n${lineas.join("\n")}${lineas.length ? "\n" : ""}`;
    })
    .join("\n");
  const previo = entrada.length ? `${entrada.join("\n")}\n\n` : "";
  return `---\n${cab}\n---\n\n${previo}${cuerpo}`;
}

export function leer(fichero) {
  if (!fs.existsSync(fichero)) throw new Error(`no existe el registro ${fichero}`);
  return parse(fs.readFileSync(fichero, "utf8"));
}

export function escribir(fichero, doc, { publicar = true } = {}) {
  doc.meta.updated = ahora();
  // 700 y 600: el registro lleva el objetivo, las decisiones y las evidencias
  // de tareas de clientes distintos, y con el umask corriente quedaba legible
  // por cualquiera en la maquina.
  fs.mkdirSync(path.dirname(fichero), { recursive: true, mode: 0o700 });
  const tmp = `${fichero}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, render(doc), { mode: 0o600 });
  fs.renameSync(tmp, fichero);
  if (publicar) publicarEnSegundoPlano(fichero);
}

// Las líneas en blanco del final de una sección son del formato, no del
// contenido: si se quedan, cada paso nuevo aparece separado del anterior.
const recortar = (s) => {
  while (s.lineas.length && s.lineas[s.lineas.length - 1].trim() === "") s.lineas.pop();
  return s;
};

const seccion = (doc, titulo) => {
  let s = doc.secciones.find((x) => x.titulo === titulo);
  if (!s) {
    s = { titulo, lineas: [] };
    doc.secciones.push(s);
  }
  return s;
};

// Una sección con solo su comentario de ayuda está vacía.
const contenido = (s) =>
  (s ? s.lineas.join("\n") : "").replace(/<!--[\s\S]*?-->/g, "").trim();

export function pasos(doc) {
  const s = doc.secciones.find((x) => x.titulo === "Pasos");
  return (s ? s.lineas : [])
    .map((l) => l.match(/^- \[( |x)\] (T\d+) (.*)$/))
    .filter(Boolean)
    .map(([, marca, id, resto]) => ({ id, hecho: marca === "x", texto: resto }));
}

// Los estados solo avanzan solos. Volver atrás es una decisión y se pide con
// `crux task status`: un seal repetido no puede devolver a "verified" algo ya
// fusionado.
export function avanzar(doc, estado) {
  const actual = ESTADOS.indexOf(doc.meta.status);
  if (ESTADOS.indexOf(estado) > actual) doc.meta.status = estado;
}

// --- Operaciones ----------------------------------------------------------------

export function crear({ tarea, proyecto, repo, espacio }) {
  const hoy = ahora();
  return {
    meta: {
      task: tarea,
      project: proyecto,
      status: "open",
      repos: repo ? [repo] : [],
      workspaces: espacio ? [espacio] : [],
      created: hoy,
      updated: hoy,
    },
    secciones: SECCIONES.map(([titulo, ayuda]) => ({ titulo, lineas: ayuda ? [`<!-- ${ayuda} -->`] : [] })),
  };
}

export function unir(doc, { repo, espacio }) {
  for (const [clave, valor] of [["repos", repo], ["workspaces", espacio]]) {
    if (!valor) continue;
    const lista = Array.isArray(doc.meta[clave]) ? doc.meta[clave] : [];
    if (!lista.includes(valor)) lista.push(valor);
    doc.meta[clave] = lista;
  }
}

export function fijar(doc, titulo, texto) {
  seccion(doc, titulo).lineas = texto.split("\n");
}

export function anotar(doc, titulo, texto) {
  const s = recortar(seccion(doc, titulo));
  s.lineas = s.lineas.filter((l) => !/^<!--.*-->$/.test(l.trim()));
  s.lineas.push(`- ${texto}`);
}

// Una decisión lleva su porqué, y opcionalmente dónde vive y qué se aprendió.
// Va en una sola línea para que el registro siga siendo una lista.
export function lineaDecision({ what, why, where, learned }) {
  return [what, why && `Why: ${why}`, where && `Where: ${where}`, learned && `Learned: ${learned}`]
    .filter(Boolean)
    .join(" · ");
}

// Las notas con porqué son decisiones: son las que tienen que durar más que la
// tarea. Las demás son desviaciones del plan y se quedan en el registro.
export function decisiones(doc) {
  return contenido(doc.secciones.find((x) => x.titulo === "Desviaciones y decisiones"))
    .split("\n")
    .filter((l) => l.startsWith("- ") && l.includes(" · Why: "))
    .map((l) => {
      const [what, ...campos] = l.slice(2).split(" · ");
      const d = { what };
      for (const c of campos) {
        const m = c.match(/^(Why|Where|Learned): (.*)$/);
        if (m) d[m[1].toLowerCase()] = m[2];
      }
      return d;
    });
}

export function anadirPaso(doc, texto) {
  const s = recortar(seccion(doc, "Pasos"));
  const n = pasos(doc).reduce((max, p) => Math.max(max, Number(p.id.slice(1))), 0) + 1;
  s.lineas.push(`- [ ] T${n} ${texto}`);
  return `T${n}`;
}

export function completar(doc, id, evidencia) {
  const s = seccion(doc, "Pasos");
  const i = s.lineas.findIndex((l) => new RegExp(`^- \\[( |x)\\] ${id} `).test(l));
  if (i < 0) throw new Error(`no hay ningún paso ${id}`);
  let linea = s.lineas[i].replace(/^- \[ \]/, "- [x]");
  if (evidencia) linea = `${linea.replace(/ · evidencia: .*$/, "")} · evidencia: ${evidencia}`;
  s.lineas[i] = linea;
  avanzar(doc, "in-progress");
}

// El recibo de la puerta es la evidencia de lo comprobado: se vuelca tal cual,
// sin resumirlo, porque resumir es donde se cuela lo que no se ejecutó.
export function verificar(doc, recibo, sha) {
  const corridas = recibo
    .split("\n")
    .map((l) => l.match(/^run (\S+) (\S+) (.*)$/))
    .filter(Boolean)
    .map(([, rc, seg, cmd]) => `- ${rc === "0" ? "ok" : `salida ${rc}`} · ${cmd} (${seg}s)`);
  fijar(doc, "Verificación", [`Sobre ${sha.slice(0, 8)}:`, "", ...corridas].join("\n"));
  avanzar(doc, "verified");
}

export function resumen(doc) {
  const ps = pasos(doc);
  const hechos = ps.filter((p) => p.hecho).length;
  const siguiente = contenido(doc.secciones.find((x) => x.titulo === "Siguiente paso")).split("\n")[0];
  const pendiente = ps.find((p) => !p.hecho);
  return {
    tarea: doc.meta.task,
    estado: doc.meta.status,
    pasos: ps.length ? `${hechos}/${ps.length}` : "",
    siguiente: siguiente || (pendiente ? `${pendiente.id} ${pendiente.texto}` : ""),
    objetivo: contenido(doc.secciones.find((x) => x.titulo === "Objetivo")).split("\n")[0],
  };
}

// La descripción de la propuesta sale del registro, pero no lo cita: en el repo
// de un cliente no se enseña cómo trabajamos por dentro. Solo lo que cambia,
// lo que se decidió y lo que se comprobó.
export function cuerpoPropuesta(doc, idioma = "en") {
  // La ruta de la maquina se quita de todo el cuerpo. Antes solo se hacia en
  // "Verificacion", y el campo de evidencia de cada paso, que es donde mas se
  // pegan rutas absolutas, salia crudo.
  const sinRutas = (t) => {
    const casa = process.env.HOME;
    let v = casa ? String(t).split(casa).join("~") : String(t);
    return v.replace(/\/(home|Users)\/[A-Za-z0-9._-]+/g, "~");
  };
  const t = idioma === "es"
    ? { cambia: "Qué cambia", alcance: "Alcance", pasos: "Hecho", decisiones: "Decisiones", comprobado: "Comprobado" }
    : { cambia: "What changes", alcance: "Scope", pasos: "Done", decisiones: "Decisions", comprobado: "Checked" };
  const bloque = (titulo, texto) => (texto ? `## ${titulo}\n\n${texto}\n` : "");
  const sec = (titulo) => contenido(doc.secciones.find((x) => x.titulo === titulo));
  const hechos = pasos(doc)
    .filter((p) => p.hecho)
    // La evidencia va entre paréntesis y sin la etiqueta: la etiqueta es del
    // idioma del registro, y la descripción puede ir en otro.
    .map((p) => `- ${p.texto.replace(/ · evidencia: (.*)$/, " ($1)")}`)
    .join("\n");
  const comprobado = sec("Verificación")
    .split("\n")
    .filter((l) => l.startsWith("- "))
    .join("\n");
  return [
    bloque(t.cambia, sinRutas(sec("Objetivo"))),
    bloque(t.alcance, sinRutas(sec("Alcance"))),
    bloque(t.pasos, sinRutas(hechos)),
    bloque(t.decisiones, sinRutas(sec("Desviaciones y decisiones"))),
    bloque(t.comprobado, sinRutas(comprobado)),
  ]
    .filter(Boolean)
    .join("\n");
}

// Archivar es cerrar y apartar: el registro deja de salir en las listas, pero
// se conserva con fecha hasta que caduque. Lo que tenía que durar ya salió a la
// propuesta y al docs repo.
export function archivar(fichero, { publicar = true } = {}) {
  const doc = leer(fichero);
  const hoy = ahora().slice(0, 10);
  doc.meta.status = "closed";
  fijar(doc, "Cierre", `closed ${hoy}`);
  const destino = path.join(path.dirname(fichero), "done", `${hoy}-${path.basename(fichero)}`);
  if (fs.existsSync(destino)) throw new Error(`ya hay un archivo con ese nombre: ${destino}`);
  escribir(destino, doc, { publicar: false });
  fs.unlinkSync(fichero);
  // Sin apuntarlo, la otra máquina volvería a subir la tarea como abierta:
  // una ausencia no distingue "archivada aquí" de "aún no ha llegado".
  apuntarBorrado(path.dirname(fichero), path.basename(fichero), render(doc));
  if (publicar) publicarEnSegundoPlano(destino);
  return destino;
}

// --- Línea de órdenes ------------------------------------------------------------

function opciones(argv) {
  const o = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i].startsWith("--")) {
      const clave = argv[i].slice(2);
      const siguiente = argv[i + 1];
      if (siguiente === undefined || siguiente.startsWith("--")) o[clave] = true;
      else o[clave] = argv[++i];
    } else o._.push(argv[i]);
  }
  return o;
}

function main() {
  const [op, ...resto] = process.argv.slice(2);
  const o = opciones(resto);
  const fichero = o.file;
  if (!fichero) throw new Error("falta --file");

  const mutar = (fn) => {
    const doc = leer(fichero);
    const salida = fn(doc);
    escribir(fichero, doc);
    return salida;
  };

  switch (op) {
    case "ensure": {
      if (fs.existsSync(fichero)) {
        mutar((doc) => unir(doc, { repo: o.repo, espacio: o.workspace }));
        console.log("joined");
      } else {
        escribir(fichero, crear({ tarea: o.task, proyecto: o.project, repo: o.repo, espacio: o.workspace }));
        console.log("created");
      }
      break;
    }
    case "set":
      mutar((doc) => fijar(doc, o.section, o.text));
      break;
    case "note":
      mutar((doc) => anotar(doc, "Desviaciones y decisiones",
        lineaDecision({ what: o.text, why: o.why, where: o.where, learned: o.learned })));
      break;
    case "decisions": {
      const doc = leer(fichero);
      console.log(JSON.stringify({ task: doc.meta.task, repos: doc.meta.repos || [], items: decisiones(doc) }));
      break;
    }
    case "add":
      console.log(mutar((doc) => anadirPaso(doc, o.text)));
      break;
    case "done":
      mutar((doc) => completar(doc, o.id, o.evidence === true ? "" : o.evidence));
      break;
    case "status": {
      if (!ESTADOS.includes(o.to)) throw new Error(`estado desconocido: ${o.to} — válidos: ${ESTADOS.join(", ")}`);
      mutar((doc) => (o.force ? (doc.meta.status = o.to) : avanzar(doc, o.to)));
      break;
    }
    case "meta":
      mutar((doc) => (doc.meta[o.key] = o.value));
      break;
    case "places": {
      // Dónde vive la tarea: repo, rama y espacio por línea. Lo lee `resume`.
      const m = leer(fichero).meta;
      const lista = (v) => (Array.isArray(v) ? v : []);
      const ramas = Object.fromEntries(lista(m.branches).map((e) => e.split("=")));
      lista(m.repos).forEach((r, i) => console.log([r, ramas[r] || "", lista(m.workspaces)[i] || ""].join("\t")));
      break;
    }
    case "branch":
      // La rama de cada repo, como repo=rama: es lo que necesita otra máquina
      // para abrir el mismo espacio desde el remoto.
      mutar((doc) => {
        const lista = (Array.isArray(doc.meta.branches) ? doc.meta.branches : [])
          .filter((e) => !e.startsWith(`${o.repo}=`));
        lista.push(`${o.repo}=${o.branch}`);
        doc.meta.branches = lista;
      });
      break;
    case "verify":
      mutar((doc) => verificar(doc, fs.readFileSync(o.receipt, "utf8"), o.sha));
      break;
    case "summary": {
      const r = resumen(leer(fichero));
      if (o.json) console.log(JSON.stringify(r));
      // Separador de unidad y no tabulador: para el shell el tabulador es
      // espacio en blanco, y dos seguidos —una tarea sin pasos— se funden en
      // uno y corren los campos.
      else console.log([r.tarea, r.estado, r.pasos, r.siguiente].join("\x1f"));
      break;
    }
    case "archive":
      console.log(archivar(fichero));
      break;
    case "body":
      process.stdout.write(cuerpoPropuesta(leer(fichero), o.lang));
      break;
    default:
      throw new Error(`operación desconocida: ${op}`);
  }
}

if (import.meta.url === `file://${process.argv[1]}` || process.argv[1]?.endsWith("/task.mjs")) {
  try {
    main();
  } catch (e) {
    console.error(e.message);
    process.exit(1);
  }
}
