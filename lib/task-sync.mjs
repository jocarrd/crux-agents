#!/usr/bin/env node
// Las tareas viajan entre máquinas: réplica de ~/.crux/tasks/<proyecto>/ en la
// rama `crux/tasks` del docs repo del proyecto. Ver ADR-016.
//
//   node lib/task-sync.mjs sync --project <p>   trae y publica un proyecto
//   node lib/task-sync.mjs sync --all           todos los que tengan tareas o rama
//   node lib/task-sync.mjs pending              los proyectos con algo sin publicar
//   node lib/task-sync.mjs open [--project <p>] las tareas abiertas, en JSON
//
// El fichero local es la fuente de verdad y la rama, su réplica. La escribe
// siempre este código y nunca el agente: con dos almacenes y alguien decidiendo
// en cada momento cuál manda, derivan.
//
// Solo plumbing de git —hash-object, write-tree, commit-tree, push—, sin
// worktree ni checkout: la rama nunca toca `main` ni el árbol de trabajo del
// docs repo, que puede estar a medias con otra cosa.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync, spawn } from "node:child_process";
import { archivar, avanzar, escribir, leer, parse } from "./task.mjs";

export const RAMA = "crux/tasks";
const REF_REMOTA = `refs/remotes/origin/${RAMA}`;
const BORRADOS = ".removed";
const ESTADOS_ABIERTOS = ["open", "planned", "in-progress", "verified", "proposed"];

// --- Dónde está cada cosa --------------------------------------------------------

function leerConfig(clave) {
  const cfg = process.env.CRUX_CONFIG || path.join(os.homedir(), ".crux/config");
  try {
    const m = fs.readFileSync(cfg, "utf8").match(new RegExp(`^${clave}="?([^"\\n]*)"?$`, "m"));
    return m ? m[1] : "";
  } catch {
    return "";
  }
}

export const raizProyectos = () =>
  process.env.CRUX_PROJECTS_DIR || leerConfig("CRUX_PROJECTS_DIR") || path.join(os.homedir(), "Proyectos");

export const dirTareas = () =>
  process.env.CRUX_TASKS_DIR ||
  path.join(path.dirname(process.env.CRUX_REGISTRY || path.join(os.homedir(), ".crux/workspaces.json")), "tasks");

const dirEstado = () =>
  path.join(process.env.CRUX_STATE_DIR || path.join(os.homedir(), ".crux/state"), "task-sync");

const esRepo = (d) => fs.existsSync(path.join(d, ".git"));

// Las tareas de un proyecto viajan en su docs repo; las de un repo suelto de
// la raíz —el propio kernel—, en ese mismo repo.
export function transporte(proyecto) {
  const raiz = raizProyectos();
  const docs = path.join(raiz, proyecto, `${proyecto}-docs`);
  if (esRepo(docs)) return docs;
  const suelto = path.join(raiz, proyecto);
  if (esRepo(suelto)) return suelto;
  return null;
}

// Lo que dice el contrato: false la desactiva, true la fuerza aunque el repo
// sea público, y sin nada decide la visibilidad. Un contrato que no se puede
// leer no se toma por "sin opinión": se para y se dice.
function preferenciaContrato(repo) {
  const f = path.join(repo, "crux.json");
  if (!fs.existsSync(f)) return undefined;
  const c = JSON.parse(fs.readFileSync(f, "utf8"));
  return c.tasks?.sync;
}

// Un registro lleva decisiones a medio pensar, evidencias y a veces datos de un
// cliente: en un repo público quedaría publicado para cualquiera. Para GitHub
// se pregunta la visibilidad y se recuerda; si no se puede saber, no se publica.
// Otros remotos —un servidor propio, un remoto local— no se pueden preguntar.
function visibilidad(repo) {
  // La URL tal como está configurada: get-url aplica los insteadOf y podría
  // esconder que detrás hay GitHub.
  const url = intentar(() => git(repo, ["config", "--get", "remote.origin.url"]).trim()) || "";
  const m = url.match(/github\.com[:/]([^/]+\/[^/]+?)(?:\.git)?$/);
  if (!m) return "otro";
  const cache = path.join(dirEstado(), "visibility.json");
  const vistas = intentar(() => JSON.parse(fs.readFileSync(cache, "utf8"))) || {};
  if (vistas[m[1]]) return vistas[m[1]];
  const v = intentar(() => execFileSync("gh", ["repo", "view", m[1], "--json", "visibility", "--jq", ".visibility"], {
    stdio: ["ignore", "pipe", "ignore"], timeout: 15000,
  }).toString().trim().toLowerCase());
  if (!v) return "desconocida";
  vistas[m[1]] = v;
  fs.mkdirSync(dirEstado(), { recursive: true, mode: 0o700 });
  escribirLocal(cache, JSON.stringify(vistas));
  return v;
}

// --- git -------------------------------------------------------------------------

function git(repo, args, { input, env } = {}) {
  return execFileSync("git", ["-C", repo, ...args], {
    input,
    env: {
      ...process.env,
      LC_ALL: "C",
      GIT_TERMINAL_PROMPT: "0",
      // Sin terminal que conteste, una pregunta de ssh colgaría la publicación.
      GIT_SSH_COMMAND: `${process.env.GIT_SSH_COMMAND || "ssh"} -o BatchMode=yes`,
      ...env,
    },
    stdio: ["pipe", "pipe", "pipe"],
    maxBuffer: 64 * 1024 * 1024,
  }).toString();
}

const intentar = (fn) => {
  try {
    return fn();
  } catch {
    return null;
  }
};

function arbolRemoto(repo) {
  const head = intentar(() => git(repo, ["rev-parse", "-q", "--verify", REF_REMOTA]).trim());
  const ficheros = new Map();
  if (!head) return { head: null, ficheros };
  for (const l of git(repo, ["ls-tree", "-r", head]).split("\n").filter(Boolean)) {
    const [meta, ruta] = l.split("\t");
    ficheros.set(ruta, meta.split(" ")[2]);
  }
  return { head, ficheros };
}

const blob = (repo, sha) => git(repo, ["cat-file", "blob", sha]);

// --- Lo local --------------------------------------------------------------------

// Las copias de un conflicto son un aviso para esta máquina, no una tarea.
const esTarea = (nombre) => nombre.endsWith(".md") && !nombre.includes(".conflicto-");

function ficherosLocales(dir) {
  const salida = [];
  for (const sub of ["", "done"]) {
    const d = path.join(dir, sub);
    if (!fs.existsSync(d)) continue;
    for (const n of fs.readdirSync(d)) {
      const ruta = sub ? `${sub}/${n}` : n;
      if (esTarea(n) && fs.statSync(path.join(dir, ruta)).isFile()) salida.push(ruta);
    }
  }
  return salida;
}

function hashes(repo, dir, rutas) {
  const m = new Map();
  if (!rutas.length) return m;
  const shas = git(repo, ["hash-object", "-w", "--stdin-paths"], {
    input: rutas.map((r) => path.join(dir, r)).join("\n") + "\n",
  }).trim().split("\n");
  rutas.forEach((r, i) => m.set(r, shas[i]));
  return m;
}

// Un borrado se apunta con la ruta y la fecha de creación de la tarea: con la
// ruta sola, una tarea nueva que reutilizara el nombre de una archivada se
// borraría en todas las máquinas nada más nacer.
const leerBorrados = (texto) => new Set(texto.split("\n").map((l) => l.trim()).filter(Boolean));
const creada = (texto) => intentar(() => parse(texto).meta.created) || "";
const claveBorrado = (ruta, texto) => `${ruta} ${creada(texto)}`.trim();
const estaBorrada = (borrados, ruta, texto) =>
  borrados.has(claveBorrado(ruta, texto)) || (!creada(texto) && borrados.has(ruta));

export function apuntarBorrado(dirProyecto, ruta, texto = "") {
  fs.mkdirSync(dirProyecto, { recursive: true, mode: 0o700 });
  fs.appendFileSync(path.join(dirProyecto, BORRADOS), `${claveBorrado(ruta, texto)}\n`, { mode: 0o600 });
}

function escribirLocal(fichero, contenido) {
  fs.mkdirSync(path.dirname(fichero), { recursive: true, mode: 0o700 });
  const tmp = `${fichero}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, contenido, { mode: 0o600 });
  fs.renameSync(tmp, fichero);
}

// Lo último que se sincronizó de cada fichero: sin ello no se distingue "lo
// cambié yo" de "lo cambiaron allí", y cualquier diferencia sería un conflicto.
const ficheroBase = (p) => path.join(dirEstado(), `${p}.json`);
const ficheroPendiente = (p) => path.join(dirEstado(), `${p}.pending`);

function leerBase(p) {
  try {
    return new Map(Object.entries(JSON.parse(fs.readFileSync(ficheroBase(p), "utf8"))));
  } catch {
    return new Map();
  }
}

function guardarBase(p, mapa) {
  fs.mkdirSync(dirEstado(), { recursive: true, mode: 0o700 });
  escribirLocal(ficheroBase(p), JSON.stringify(Object.fromEntries(mapa), null, 1));
}

export function marcarPendiente(p) {
  fs.mkdirSync(dirEstado(), { recursive: true, mode: 0o700 });
  fs.writeFileSync(ficheroPendiente(p), new Date().toISOString(), { mode: 0o600 });
}

const actualizado = (texto) => intentar(() => parse(texto).meta.updated) || "";

// --- Un proyecto -----------------------------------------------------------------

const maquina = () => os.hostname().split(".")[0].replace(/[^A-Za-z0-9-]/g, "") || "maquina";

function fusionar(p, repo) {
  const dir = path.join(dirTareas(), p);
  const avisos = [];
  const cambios = { traidas: 0, publicadas: 0 };

  const remoto = arbolRemoto(repo);
  const base = leerBase(p);
  const locales = hashes(repo, dir, ficherosLocales(dir));

  const borradosLocal = fs.existsSync(path.join(dir, BORRADOS))
    ? fs.readFileSync(path.join(dir, BORRADOS), "utf8") : "";
  const borradosRemoto = remoto.ficheros.has(BORRADOS) ? blob(repo, remoto.ficheros.get(BORRADOS)) : "";
  const borrados = new Set([...leerBorrados(borradosLocal), ...leerBorrados(borradosRemoto)]);

  const final = new Map();
  const rutas = new Set([...locales.keys(), ...remoto.ficheros.keys()]);
  rutas.delete(BORRADOS);

  for (const ruta of rutas) {
    let L = locales.get(ruta), R = remoto.ficheros.get(ruta);
    const B = base.get(ruta);
    const local = path.join(dir, ruta);

    // Cada versión se mira por separado: la de aquí puede ser la tarea que se
    // archivó y la del remoto, otra nueva con el mismo nombre. Lo archivado se
    // trata como si no estuviera.
    if (L && estaBorrada(borrados, ruta, fs.readFileSync(local, "utf8"))) {
      // Si aquí se había tocado después de sincronizar, se guarda aparte.
      if (B && L !== B) {
        escribirLocal(local.replace(/\.md$/, `.conflicto-${maquina()}.md`), fs.readFileSync(local, "utf8"));
        avisos.push(`${p}/${ruta}: la archivaron en otra máquina y aquí tenía cambios — guardados aparte`);
      }
      fs.unlinkSync(local);
      L = undefined;
    }
    if (R && estaBorrada(borrados, ruta, blob(repo, R))) R = undefined;
    if (!L && !R) continue;

    if (L && L === R) { final.set(ruta, L); continue; }
    if (L && !R) { final.set(ruta, L); cambios.publicadas++; continue; }
    if (!L && R) {
      if (B && B === R) {
        // Estaba sincronizada y aquí ya no existe: se borró a mano sin pasar
        // por crux. Se respeta y se apunta, para que no vuelva.
        borrados.add(claveBorrado(ruta, blob(repo, R)));
        continue;
      }
      escribirLocal(local, blob(repo, R));
      final.set(ruta, R);
      cambios.traidas++;
      continue;
    }
    // Las dos existen y son distintas.
    if (L === B) {
      escribirLocal(local, blob(repo, R));
      final.set(ruta, R);
      cambios.traidas++;
    } else if (R === B) {
      final.set(ruta, L);
      cambios.publicadas++;
    } else {
      // Cambió en las dos. Gana la más reciente; la otra se queda al lado.
      const textoL = fs.readFileSync(local, "utf8"), textoR = blob(repo, R);
      const ganaRemota = actualizado(textoR) > actualizado(textoL);
      const perdedora = ganaRemota ? textoL : textoR;
      escribirLocal(local.replace(/\.md$/, `.conflicto-${ganaRemota ? maquina() : "remota"}.md`), perdedora);
      if (ganaRemota) {
        escribirLocal(local, textoR);
        final.set(ruta, R);
        cambios.traidas++;
      } else {
        final.set(ruta, L);
        cambios.publicadas++;
      }
      avisos.push(`${p}/${ruta}: cambió en las dos máquinas — se queda la más reciente y la otra, al lado como .conflicto-`);
    }
  }

  // Lo borrado viaja como lista, no como ausencia: una ausencia no distingue
  // "lo archivé aquí" de "aún no me ha llegado".
  const textoBorrados = [...borrados].sort().join("\n") + (borrados.size ? "\n" : "");
  if (borrados.size) {
    fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
    escribirLocal(path.join(dir, BORRADOS), textoBorrados);
  }

  // El árbol que debería tener la rama.
  const indice = path.join(os.tmpdir(), `crux-task-sync-${process.pid}-${Date.now()}`);
  const env = { GIT_INDEX_FILE: indice };
  try {
    const entradas = [...final.entries()];
    if (borrados.size) {
      entradas.push([BORRADOS, git(repo, ["hash-object", "-w", "--stdin"], { input: textoBorrados }).trim()]);
    }
    git(repo, ["read-tree", "--empty"], { env });
    if (entradas.length) {
      git(repo, ["update-index", "--add", "--index-info"], {
        env,
        input: entradas.map(([r, sha]) => `100644 ${sha}\t${r}`).join("\n") + "\n",
      });
    }
    const arbol = git(repo, ["write-tree"], { env }).trim();
    const arbolActual = remoto.head ? git(repo, ["rev-parse", `${remoto.head}^{tree}`]).trim() : null;
    let commit = null;
    if (arbol !== arbolActual && entradas.length) {
      commit = git(repo, [
        // Sin firma: con commit.gpgSign activo, commit-tree pediría una clave.
        "commit-tree", "--no-gpg-sign", arbol, ...(remoto.head ? ["-p", remoto.head] : []),
        // [skip ci]: la rama de tareas no tiene nada que comprobar, y cada
        // publicación gastaría minutos de CI del docs repo.
        "-m", `[skip ci] tasks: ${maquina()}`,
      ], { env: { GIT_AUTHOR_NAME: "crux", GIT_AUTHOR_EMAIL: "crux@localhost",
        GIT_COMMITTER_NAME: "crux", GIT_COMMITTER_EMAIL: "crux@localhost" } }).trim();
    }
    return { commit, final, avisos, cambios, borrados };
  } finally {
    fs.rmSync(indice, { force: true });
  }
}

// Una tarea cuya propuesta se fusionó por fuera de `crux merge` se quedaba en
// "proposed" para siempre, y el recordatorio la enseñaría en cada sesión. Aquí
// se pregunta a GitHub por las que tienen propuesta y aún no constan como
// fusionadas: se marcan, y si no tienen espacio vivo en esta máquina, se
// archivan, porque no queda nada que retomar. Sin gh, no se toca nada.
function reconciliar(p) {
  const dir = path.join(dirTareas(), p);
  if (!fs.existsSync(dir)) return [];
  const cache = path.join(dirEstado(), "pr-state.json");
  const visto = intentar(() => JSON.parse(fs.readFileSync(cache, "utf8"))) || {};
  const vivos = espaciosVivos();
  const hechas = [];
  for (const n of fs.readdirSync(dir)) {
    if (!esTarea(n)) continue;
    const f = path.join(dir, n);
    const doc = intentar(() => leer(f));
    const pr = doc?.meta.pr;
    if (!pr || !["verified", "proposed"].includes(doc.meta.status)) continue;
    // Una propuesta abierta se vuelve a mirar como mucho cada seis horas.
    if (visto[pr] && Date.now() - visto[pr] < 6 * 3600000) continue;
    const estado = intentar(() => execFileSync("gh", ["pr", "view", pr, "--json", "state", "--jq", ".state"], {
      stdio: ["ignore", "pipe", "ignore"], timeout: 15000,
    }).toString().trim());
    if (estado === null) break;
    visto[pr] = Date.now();
    if (estado !== "MERGED") continue;
    avanzar(doc, "merged");
    escribir(f, doc, { publicar: false });
    const vivo = (Array.isArray(doc.meta.workspaces) ? doc.meta.workspaces : []).some((e) => vivos.has(e));
    if (!vivo) intentar(() => archivar(f, { publicar: false }));
    hechas.push(`${p}/${doc.meta.task}: su propuesta ya estaba fusionada — ${vivo ? "marcada" : "archivada"}`);
  }
  fs.mkdirSync(dirEstado(), { recursive: true, mode: 0o700 });
  escribirLocal(cache, JSON.stringify(visto));
  return hechas;
}

// Candado por proyecto: la publicación en segundo plano de una escritura y la
// de `crux sync` no pueden fusionar a la vez sobre el mismo estado.
function conCandado(p, fn) {
  fs.mkdirSync(dirEstado(), { recursive: true, mode: 0o700 });
  const candado = path.join(dirEstado(), `${p}.lock`);
  for (let i = 0; ; i++) {
    try {
      fs.mkdirSync(candado);
      break;
    } catch {
      const viejo = intentar(() => Date.now() - fs.statSync(candado).mtimeMs > 120000);
      if (viejo) { fs.rmSync(candado, { recursive: true, force: true }); continue; }
      if (i > 600) throw new Error(`${p}: otra sincronización de tareas no termina`);
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 100);
    }
  }
  try {
    return fn();
  } finally {
    fs.rmSync(candado, { recursive: true, force: true });
  }
}

// Un solo viaje al remoto: cada uno cuesta segundos por ssh. El error del fetch
// distingue que la rama aún no exista de que no haya red.
function traerRama(repo) {
  try {
    git(repo, ["fetch", "-q", "origin", `+refs/heads/${RAMA}:${REF_REMOTA}`]);
    return "ok";
  } catch (e) {
    if (/couldn't find remote ref/i.test(String(e.stderr || ""))) {
      intentar(() => git(repo, ["update-ref", "-d", REF_REMOTA]));
      return "sin-rama";
    }
    return "sin-red";
  }
}

export function sincronizarProyecto(p, { yaTraida = false } = {}) {
  const repo = transporte(p);
  if (!repo) return { proyecto: p, estado: "sin-transporte" };
  const preferencia = preferenciaContrato(repo);
  if (preferencia === false) return { proyecto: p, estado: "desactivado" };
  if (!intentar(() => git(repo, ["remote", "get-url", "origin"]))) return { proyecto: p, estado: "sin-remoto" };
  if (preferencia !== true) {
    const v = visibilidad(repo);
    if (v === "public") return { proyecto: p, estado: "publico" };
    if (v === "desconocida") {
      marcarPendiente(p);
      return { proyecto: p, estado: "sin-comprobar" };
    }
  }

  return conCandado(p, () => {
    // Se borra antes de empezar: una escritura que llegue durante la
    // sincronización la vuelve a marcar y no se pierde.
    fs.rmSync(ficheroPendiente(p), { force: true });
    let ultimo = null;
    for (let intento = 0; intento < 4; intento++) {
      // `crux sync` acaba de traer todos los remotos, rama de tareas incluida:
      // en la primera vuelta basta con lo que ya hay. Si al publicar resulta que
      // el remoto avanzó, la segunda sí va a buscarlo.
      const traida = yaTraida && intento === 0 ? "ok" : traerRama(repo);
      if (traida === "sin-red") {
        marcarPendiente(p);
        return { proyecto: p, estado: "sin-red" };
      }
      const hayRama = intentar(() => git(repo, ["rev-parse", "-q", "--verify", REF_REMOTA]));
      // Ni rama en el remoto ni tareas aquí: nada que hacer.
      if (!hayRama && !fs.existsSync(path.join(dirTareas(), p))) {
        return { proyecto: p, estado: "ok", traidas: 0, publicadas: 0, avisos: [] };
      }
      ultimo = fusionar(p, repo);
      if (!ultimo.commit) {
        guardarBase(p, ultimo.final);
        return { proyecto: p, estado: "ok", ...ultimo.cambios, avisos: ultimo.avisos };
      }
      // Sin hooks: la rama es interna, y un pre-push del docs repo —el que cierra
      // la principal, o uno que pase tests— no tiene nada que decir de ella.
      if (intentar(() => git(repo, ["push", "-q", "--no-verify", "origin", `${ultimo.commit}:refs/heads/${RAMA}`])) !== null) {
        git(repo, ["update-ref", REF_REMOTA, ultimo.commit]);
        guardarBase(p, ultimo.final);
        return { proyecto: p, estado: "ok", ...ultimo.cambios, avisos: ultimo.avisos };
      }
      // Otra máquina publicó entre medias: se vuelve a traer y a fusionar.
    }
    marcarPendiente(p);
    return { proyecto: p, estado: "rechazado", avisos: ultimo?.avisos || [] };
  });
}

// Los proyectos que pueden tener algo que sincronizar: los que tienen tareas
// aquí, todos los que tienen docs repo —en una máquina que llega, sus tareas
// solo existen en el remoto— y los repos sueltos cuya rama de tareas ya trajo
// el fetch de `crux sync`.
export function proyectosConTareas() {
  const p = new Set();
  const dt = dirTareas();
  if (fs.existsSync(dt)) for (const n of fs.readdirSync(dt)) if (fs.statSync(path.join(dt, n)).isDirectory()) p.add(n);
  const raiz = raizProyectos();
  if (fs.existsSync(raiz)) {
    for (const n of fs.readdirSync(raiz)) {
      if (p.has(n) || n.includes("-ws-")) continue;
      if (esRepo(path.join(raiz, n, `${n}-docs`))) { p.add(n); continue; }
      const repo = transporte(n);
      if (repo && intentar(() => git(repo, ["rev-parse", "-q", "--verify", REF_REMOTA]))) p.add(n);
    }
  }
  return [...p].sort();
}

export function pendientes() {
  if (!fs.existsSync(dirEstado())) return [];
  return fs.readdirSync(dirEstado()).filter((n) => n.endsWith(".pending")).map((n) => n.slice(0, -8)).sort();
}

// Las tareas abiertas, para enseñarlas al empezar una sesión.
export function abiertas(proyecto) {
  const dt = dirTareas();
  if (!fs.existsSync(dt)) return [];
  const proyectos = proyecto ? [proyecto] : fs.readdirSync(dt);
  const salida = [];
  for (const p of proyectos) {
    const dir = path.join(dt, p);
    if (!fs.existsSync(dir) || !fs.statSync(dir).isDirectory()) continue;
    for (const n of fs.readdirSync(dir)) {
      if (!esTarea(n)) continue;
      const doc = intentar(() => parse(fs.readFileSync(path.join(dir, n), "utf8")));
      if (!doc || !ESTADOS_ABIERTOS.includes(doc.meta.status)) continue;
      const sec = (t) => (doc.secciones.find((s) => s.titulo === t)?.lineas.join("\n") || "")
        .replace(/<!--[\s\S]*?-->/g, "").trim().split("\n")[0];
      salida.push({
        proyecto: p,
        tarea: doc.meta.task || n.slice(0, -3),
        estado: doc.meta.status,
        actualizada: doc.meta.updated || "",
        siguiente: sec("Siguiente paso") || sec("Objetivo"),
        espacios: Array.isArray(doc.meta.workspaces) ? doc.meta.workspaces : [],
      });
    }
  }
  return salida.sort((a, b) => (b.actualizada > a.actualizada ? 1 : -1));
}

// --- El recordatorio ---------------------------------------------------------------
//
// Al empezar o retomar una sesión se enseñan las tareas abiertas. Es un
// recordatorio y nada más: quien decide si se retoma alguna es la persona, y
// si pide otra cosa, se hace otra cosa. Por eso van dos textos: uno que ve ella
// tal cual, y otro para el agente que dice expresamente que no las empuje.

function proyectoDe(cwd) {
  const raiz = path.resolve(raizProyectos());
  const rel = path.relative(raiz, path.resolve(cwd || "."));
  if (!rel || rel.startsWith("..") || path.isAbsolute(rel)) return null;
  return rel.split(path.sep)[0].replace(/-ws-.*$/, "");
}

function espaciosVivos() {
  const f = process.env.CRUX_REGISTRY || path.join(os.homedir(), ".crux/workspaces.json");
  const vivos = new Set();
  const r = intentar(() => JSON.parse(fs.readFileSync(f, "utf8")));
  for (const [n, w] of Object.entries(r?.workspaces || {})) if (w.path && fs.existsSync(w.path)) vivos.add(n);
  return vivos;
}

const hace = (fecha) => {
  const t = Date.parse(fecha);
  if (Number.isNaN(t)) return "";
  const d = Math.floor((Date.now() - t) / 86400000);
  return d <= 0 ? "hoy" : d === 1 ? "ayer" : `hace ${d} días`;
};

export function recordatorio(cwd, maximo = 6) {
  const proyecto = proyectoDe(cwd);
  let lista = abiertas(proyecto && fs.existsSync(path.join(dirTareas(), proyecto)) ? proyecto : undefined);
  if (!lista.length) return null;
  const vivos = espaciosVivos();
  const recortar = (t, n) => (t.length > n ? `${t.slice(0, n - 1)}…` : t);
  // Los mismos datos que el texto, para quien los pinte de otra forma (el mod
  // de Claude Code los dibuja como panel).
  const tareas = lista.slice(0, maximo).map((t) => ({
    tarea: `${t.proyecto}/${t.tarea}`,
    nombre: t.tarea,
    estado: t.estado,
    cuando: hace(t.actualizada),
    siguiente: t.siguiente || "",
    aqui: t.espacios.some((e) => vivos.has(e)),
  }));
  const lineas = lista.slice(0, maximo).map((t) => {
    const aqui = t.espacios.some((e) => vivos.has(e));
    // Una línea por tarea: el control remoto del móvil pinta cada línea como un aviso aparte
    const estado = t.estado === "open" ? "" : `${t.estado}, `;
    return `· ${t.proyecto}/${t.tarea} (${estado}${hace(t.actualizada)})` +
      (t.siguiente ? `: ${recortar(t.siguiente, 70)}` : "") +
      (aqui ? "" : ` · sin espacio aquí: crux workspace resume ${t.tarea}`);
  });
  if (lista.length > maximo) lineas.push(`· y ${lista.length - maximo} más: crux status`);
  const conflictos = [];
  for (const p of new Set(lista.map((t) => t.proyecto))) {
    const dir = path.join(dirTareas(), p);
    for (const n of intentar(() => fs.readdirSync(dir)) || []) if (n.includes(".conflicto-")) conflictos.push(path.join(dir, n));
  }
  if (conflictos.length) {
    lineas.push(`· ${conflictos.length === 1 ? "hay 1 copia" : `hay ${conflictos.length} copias`} de un conflicto entre máquinas por revisar: ${path.dirname(conflictos[0])}`);
  }
  const titulo = proyecto && lista.every((t) => t.proyecto === proyecto)
    ? `Tareas abiertas en ${proyecto}` : "Tareas abiertas";
  const usuario = `${titulo}, por si quieres retomar alguna:\n${lineas.join("\n")}`;
  const agente = [
    `${titulo} de esta persona (ya se le han mostrado):`,
    ...lineas,
    "",
    "Es solo un recordatorio. No retomes ninguna ni la propongas por tu cuenta, y no insistas:",
    "si pide otra cosa, haz esa otra cosa. Si decide retomar una que no tiene espacio en este",
    "ordenador, se abre con `crux workspace resume <tarea>`.",
  ].join("\n");
  return { usuario, agente, titulo, tareas, mas: Math.max(0, lista.length - maximo), conflictos: conflictos.length };
}

// Tras cada escritura: publicar sin hacer esperar a quien escribe. La marca de
// pendiente va antes, en el mismo proceso, para que si esto no llega a correr
// —sin red, apagado— `crux sync --leave` lo sepa.
export function publicarEnSegundoPlano(fichero) {
  if (process.env.CRUX_IN_TESTS === "1" && process.env.CRUX_TASK_SYNC !== "1") return;
  if (process.env.CRUX_TASK_SYNC === "0") return;
  let dir = path.dirname(fichero);
  if (path.basename(dir) === "done") dir = path.dirname(dir);
  if (path.dirname(dir) !== path.resolve(dirTareas())) return;
  const p = path.basename(dir);
  intentar(() => marcarPendiente(p));
  intentar(() => {
    const hijo = spawn(process.execPath, [new URL(import.meta.url).pathname, "sync", "--project", p], {
      detached: true,
      stdio: "ignore",
    });
    hijo.unref();
  });
}

// --- Línea de órdenes --------------------------------------------------------------

function main() {
  const [op, ...resto] = process.argv.slice(2);
  const valor = (k) => {
    const i = resto.indexOf(`--${k}`);
    return i >= 0 ? resto[i + 1] : undefined;
  };
  switch (op) {
    case "sync": {
      const lista = resto.includes("--all") ? proyectosConTareas() : [valor("project")].filter(Boolean);
      if (!lista.length && !resto.includes("--all")) throw new Error("falta --project o --all");
      const r = lista.map((p) => {
        try {
          // Solo en las rondas completas: la publicación tras cada escritura
          // tiene que ser rápida y no hablar con nadie más que con git.
          // Primero se trae: lo que hay que reconciliar puede venir de la otra
          // máquina. Si se cierra algo, se vuelve a publicar.
          const opciones = { yaTraida: resto.includes("--fetched") };
          let s = sincronizarProyecto(p, opciones);
          const cerradas = resto.includes("--all") && s.estado === "ok" ? reconciliar(p) : [];
          if (cerradas.length) {
            const antes = s;
            s = sincronizarProyecto(p, opciones);
            s.traidas = antes.traidas;
            s.avisos = [...(antes.avisos || []), ...(s.avisos || [])];
            s.cerradas = cerradas;
          }
          return s;
        } catch (e) {
          return { proyecto: p, estado: "fallo", motivo: String(e.message || e).split("\n")[0] };
        }
      });
      console.log(JSON.stringify(r));
      break;
    }
    case "projects":
      console.log(proyectosConTareas().join("\n"));
      break;
    case "pending":
      console.log(pendientes().join("\n"));
      break;
    case "open":
      console.log(JSON.stringify(abiertas(valor("project"))));
      break;
    case "remind": {
      const r = recordatorio(valor("cwd") || process.cwd());
      if (r) console.log(JSON.stringify(r));
      break;
    }
    default:
      throw new Error(`operación desconocida: ${op}`);
  }
}

if (process.argv[1] && process.argv[1].endsWith("/task-sync.mjs")) {
  try {
    main();
  } catch (e) {
    console.error(e.message);
    process.exit(1);
  }
}
