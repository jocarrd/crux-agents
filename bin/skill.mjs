#!/usr/bin/env node
// crux skill — probar que una skill sigue haciendo lo que tiene que hacer.
//
//   crux skill test <skill|ruta> [--against <ref>] [--runs <n>] [--verbose]
//
// Pasa los escenarios de <skill>/tests/escenarios.md: preguntas con respuesta
// conocida y comprobaciones deterministas. Cuenta las palabras y, si el
// adaptador lo permite, los tokens. Con --against compara con la versión de
// esa referencia de git y marca como regresión lo que antes pasaba y ahora no.
//
// Quién responde lo decide el adaptador, no este comando:
//   CRUX_SKILL_RUNNER  responde a la pregunta de la entrada estándar siguiendo
//                      $CRUX_SKILL_FILE (por defecto, el adaptador de Claude)
//   CRUX_SKILL_TOKENS  imprime los tokens de $CRUX_SKILL_FILE (opcional)

import { readFileSync, writeFileSync, existsSync, mkdtempSync, statSync } from "node:fs";
import { join, dirname, basename, resolve, relative } from "node:path";
import { tmpdir } from "node:os";
import { spawnSync } from "node:child_process";

const CRUX_HOME = process.env.CRUX_HOME || resolve(dirname(new URL(import.meta.url).pathname), "..");

function fallar(msg, code = 2) {
  console.error(`error ${msg}`);
  process.exit(code);
}

// Un escenario: «## nombre», «Pregunta:» (puede seguir en varias líneas),
// «Debe:» y «No debe:», una expresión regular por línea. Todas las «Debe»
// tienen que casar y ninguna «No debe».
export function leerEscenarios(texto) {
  const out = [];
  let cur = null, campo = null;
  for (const linea of texto.split("\n")) {
    const h = linea.match(/^##\s+(.+)$/);
    if (h) { cur = { nombre: h[1].trim(), pregunta: "", debe: [], noDebe: [] }; out.push(cur); campo = null; continue; }
    if (!cur) continue;
    const m = linea.match(/^(Pregunta|Debe|No debe):\s*(.*)$/i);
    if (m) {
      campo = m[1].toLowerCase();
      if (campo === "pregunta") cur.pregunta = m[2];
      else (campo === "debe" ? cur.debe : cur.noDebe).push(m[2]);
      continue;
    }
    if (campo === "pregunta" && linea.trim()) cur.pregunta += "\n" + linea;
  }
  for (const e of out) {
    if (!e.pregunta.trim()) fallar(`el escenario «${e.nombre}» no tiene pregunta`);
    if (!e.debe.length && !e.noDebe.length) fallar(`el escenario «${e.nombre}» no comprueba nada: le falta «Debe:» o «No debe:»`);
  }
  return out;
}

export function comprobar(escenario, respuesta) {
  const fallos = [];
  for (const r of escenario.debe) if (!new RegExp(r, "iu").test(respuesta)) fallos.push(`no dice /${r}/`);
  for (const r of escenario.noDebe) if (new RegExp(r, "iu").test(respuesta)) fallos.push(`dice /${r}/`);
  return fallos;
}

function localizar(arg) {
  const candidatos = [arg, join(arg, "SKILL.md"), join(CRUX_HOME, "skills", arg, "SKILL.md")];
  for (const c of candidatos) {
    if (existsSync(c) && statSync(c).isFile() && basename(c) === "SKILL.md") return resolve(c);
  }
  fallar(`no encuentro la skill «${arg}»: pasa su nombre en el kernel o la ruta de su carpeta`);
}

function version(skillPath, ref) {
  const repo = spawnSync("git", ["-C", dirname(skillPath), "rev-parse", "--show-toplevel"], { encoding: "utf8" });
  if (repo.status !== 0) fallar(`--against necesita que la skill esté en un repo de git`);
  const rel = relative(repo.stdout.trim(), skillPath);
  const r = spawnSync("git", ["-C", repo.stdout.trim(), "show", `${ref}:${rel}`], { encoding: "utf8" });
  if (r.status !== 0) fallar(`no existe ${rel} en ${ref}`);
  return r.stdout;
}

function adaptador(nombreEnv, script) {
  if (process.env[nombreEnv]) return process.env[nombreEnv];
  const p = join(CRUX_HOME, "adapters", "claude", script);
  const hay = spawnSync("bash", ["-c", "command -v claude"], { encoding: "utf8" }).status === 0;
  return hay && existsSync(p) ? `bash ${JSON.stringify(p)}` : null;
}

function ejecutar(cmd, skillFile, entrada) {
  const r = spawnSync("bash", ["-c", cmd], {
    input: entrada ?? "", encoding: "utf8", maxBuffer: 16 * 1024 * 1024,
    env: { ...process.env, CRUX_SKILL_FILE: skillFile },
  });
  if (r.status !== 0) return { error: (r.stderr || r.stdout || `salida ${r.status}`).trim().split("\n").slice(-3).join(" ") };
  return { salida: r.stdout.trim() };
}

const palabras = (t) => (t.trim() ? t.trim().split(/\s+/).length : 0);

function probar(etiqueta, texto, escenarios, runner, tokensCmd, runs) {
  const dir = mkdtempSync(join(tmpdir(), "crux-skill-"));
  const fichero = join(dir, "SKILL.md");
  writeFileSync(fichero, texto);
  let tokens = null;
  if (tokensCmd) {
    const t = ejecutar(tokensCmd, fichero);
    tokens = t.error ? null : Number(t.salida) || null;
  }
  const resultados = escenarios.map((e) => {
    const intentos = [];
    for (let i = 0; i < runs; i++) {
      const r = ejecutar(runner, fichero, e.pregunta);
      if (r.error) fallar(`el adaptador falló en «${e.nombre}»: ${r.error}`, 1);
      intentos.push({ respuesta: r.salida, fallos: comprobar(e, r.salida) });
    }
    return { nombre: e.nombre, intentos, pasa: intentos.every((x) => !x.fallos.length) };
  });
  return { etiqueta, palabras: palabras(texto), tokens, resultados };
}

function main() {
  const [op, ...resto] = process.argv.slice(2);
  if (op !== "test") fallar("uso: crux skill test <skill|ruta> [--against <ref>] [--runs <n>] [--verbose]");
  let objetivo = null, contra = null, runs = 1, verbose = false;
  for (let i = 0; i < resto.length; i++) {
    const a = resto[i];
    if (a === "--against") contra = resto[++i];
    else if (a === "--runs") runs = Math.max(1, Number(resto[++i]) || 1);
    else if (a === "--verbose") verbose = true;
    else if (a.startsWith("--")) fallar(`opción desconocida: ${a}`);
    else objetivo = a;
  }
  if (!objetivo) fallar("falta la skill: crux skill test <skill|ruta>");
  const skill = localizar(objetivo);
  const escFile = join(dirname(skill), "tests", "escenarios.md");
  if (!existsSync(escFile)) fallar(`la skill no tiene escenarios: crea ${relative(process.cwd(), escFile)} (ver /skill-creator)`);
  const escenarios = leerEscenarios(readFileSync(escFile, "utf8"));
  if (!escenarios.length) fallar(`${escFile} no tiene ningún escenario («## nombre»)`);

  const runner = adaptador("CRUX_SKILL_RUNNER", "skill-runner.sh");
  if (!runner) fallar("no hay quién responda: define CRUX_SKILL_RUNNER o instala el agente del adaptador por defecto");
  const tokensCmd = adaptador("CRUX_SKILL_TOKENS", "skill-tokens.sh");

  const nombre = basename(dirname(skill));
  const actual = probar("actual", readFileSync(skill, "utf8"), escenarios, runner, tokensCmd, runs);
  const previa = contra ? probar(contra, version(skill, contra), escenarios, runner, tokensCmd, runs) : null;

  const tam = (v) => `${v.palabras} palabras${v.tokens ? ` · ${v.tokens} tokens` : ""}`;
  console.log(`skill ${nombre}: ${escenarios.length} escenarios${runs > 1 ? ` × ${runs}` : ""}`);
  console.log(`  actual: ${tam(actual)}`);
  if (previa) {
    let delta = "";
    if (actual.tokens && previa.tokens) delta = ` (${Math.round((actual.tokens - previa.tokens) * 100 / previa.tokens)} % de tokens)`;
    console.log(`  ${contra}: ${tam(previa)}${delta}`);
  }
  console.log("");

  let fallan = 0, regresiones = 0;
  actual.resultados.forEach((r, i) => {
    const antes = previa?.resultados[i];
    const marca = r.pasa ? "ok  " : (antes?.pasa ? "REGR" : "FALLA");
    if (!r.pasa) fallan++;
    if (!r.pasa && antes?.pasa) regresiones++;
    const extra = antes ? `   (${contra}: ${antes.pasa ? "ok" : "falla"})` : "";
    console.log(`${marca}  ${r.nombre}${extra}`);
    if (!r.pasa || verbose) {
      for (const [k, it] of r.intentos.entries()) {
        if (it.fallos.length) console.log(`      ${runs > 1 ? `intento ${k + 1}: ` : ""}${it.fallos.join(" · ")}`);
        if (verbose || it.fallos.length) console.log(`      › ${it.respuesta.replace(/\s+/g, " ").slice(0, 300)}`);
      }
    }
  });
  console.log("");
  if (regresiones) console.log(`${regresiones} regresión(es): la versión actual falla donde ${contra} pasaba`);
  console.log(fallan ? `${fallan} de ${escenarios.length} escenarios fallan` : "todos los escenarios pasan");
  process.exit(fallan ? 1 : 0);
}

if (import.meta.url === `file://${process.argv[1]}`) main();
