#!/usr/bin/env node
// crux skill — test that a skill still does what it has to do.
//
//   crux skill test <skill|path> [--against <ref>] [--runs <n>] [--verbose]
//
// Runs the scenarios in <skill>/tests/escenarios.md: questions with a known
// answer and deterministic checks. Counts the words and, if the adapter
// allows it, the tokens. With --against it compares with the version at that
// git ref and flags as a regression what used to pass and now does not.
//
// Who answers is decided by the adapter, not by this command:
//   CRUX_SKILL_RUNNER  answers the question on stdin following
//                      $CRUX_SKILL_FILE (by default, the Claude adapter)
//   CRUX_SKILL_TOKENS  prints the tokens of $CRUX_SKILL_FILE (optional)

import { readFileSync, writeFileSync, existsSync, mkdtempSync, statSync } from "node:fs";
import { join, dirname, basename, resolve, relative } from "node:path";
import { tmpdir } from "node:os";
import { spawnSync } from "node:child_process";

const CRUX_HOME = process.env.CRUX_HOME || resolve(dirname(new URL(import.meta.url).pathname), "..");

function fail(msg, code = 2) {
  console.error(`error ${msg}`);
  process.exit(code);
}

// A scenario: «## name», «Question:» (may continue over several lines),
// «Must:» and «Must not:», one regular expression per line. Every «Must» has
// to match and no «Must not» may. The Spanish keywords («Pregunta:», «Debe:»,
// «No debe:») of existing scenario files are still accepted.
export function readScenarios(text) {
  const out = [];
  let cur = null, field = null;
  for (const line of text.split("\n")) {
    const h = line.match(/^##\s+(.+)$/);
    if (h) { cur = { name: h[1].trim(), question: "", must: [], mustNot: [] }; out.push(cur); field = null; continue; }
    if (!cur) continue;
    const m = line.match(/^(Question|Must not|Must|Pregunta|No debe|Debe):\s*(.*)$/i);
    if (m) {
      const key = m[1].toLowerCase();
      field = key === "pregunta" ? "question" : key === "debe" ? "must" : key === "no debe" ? "mustNot" : key.replace(" n", "N");
      if (field === "question") cur.question = m[2];
      else cur[field].push(m[2]);
      continue;
    }
    if (field === "question" && line.trim()) cur.question += "\n" + line;
  }
  for (const e of out) {
    if (!e.question.trim()) fail(`scenario «${e.name}» has no question`);
    if (!e.must.length && !e.mustNot.length) fail(`scenario «${e.name}» checks nothing: it lacks «Must:» or «Must not:»`);
  }
  return out;
}

export function check(scenario, answer) {
  const failures = [];
  for (const r of scenario.must) if (!new RegExp(r, "iu").test(answer)) failures.push(`does not say /${r}/`);
  for (const r of scenario.mustNot) if (new RegExp(r, "iu").test(answer)) failures.push(`says /${r}/`);
  return failures;
}

function locate(arg) {
  const candidates = [arg, join(arg, "SKILL.md"), join(CRUX_HOME, "skills", arg, "SKILL.md")];
  for (const c of candidates) {
    if (existsSync(c) && statSync(c).isFile() && basename(c) === "SKILL.md") return resolve(c);
  }
  fail(`cannot find skill «${arg}»: pass its name in the kernel or the path of its folder`);
}

function version(skillPath, ref) {
  const repo = spawnSync("git", ["-C", dirname(skillPath), "rev-parse", "--show-toplevel"], { encoding: "utf8" });
  if (repo.status !== 0) fail(`--against needs the skill to be in a git repo`);
  const rel = relative(repo.stdout.trim(), skillPath);
  const r = spawnSync("git", ["-C", repo.stdout.trim(), "show", `${ref}:${rel}`], { encoding: "utf8" });
  if (r.status !== 0) fail(`${rel} does not exist in ${ref}`);
  return r.stdout;
}

function adapter(envName, script) {
  if (process.env[envName]) return process.env[envName];
  const p = join(CRUX_HOME, "adapters", "claude", script);
  const found = spawnSync("bash", ["-c", "command -v claude"], { encoding: "utf8" }).status === 0;
  return found && existsSync(p) ? `bash ${JSON.stringify(p)}` : null;
}

function run(cmd, skillFile, preamble) {
  const r = spawnSync("bash", ["-c", cmd], {
    input: preamble ?? "", encoding: "utf8", maxBuffer: 16 * 1024 * 1024,
    env: { ...process.env, CRUX_SKILL_FILE: skillFile },
  });
  if (r.status !== 0) return { error: (r.stderr || r.stdout || `exit ${r.status}`).trim().split("\n").slice(-3).join(" ") };
  return { output: r.stdout.trim() };
}

const words = (t) => (t.trim() ? t.trim().split(/\s+/).length : 0);

function tryOut(label, text, scenarios, runner, tokensCmd, runs) {
  const dir = mkdtempSync(join(tmpdir(), "crux-skill-"));
  const file = join(dir, "SKILL.md");
  writeFileSync(file, text);
  let tokens = null;
  if (tokensCmd) {
    const t = run(tokensCmd, file);
    tokens = t.error ? null : Number(t.output) || null;
  }
  const results = scenarios.map((e) => {
    const attempts = [];
    for (let i = 0; i < runs; i++) {
      const r = run(runner, file, e.question);
      if (r.error) fail(`the adapter failed on «${e.name}»: ${r.error}`, 1);
      attempts.push({ answer: r.output, failures: check(e, r.output) });
    }
    return { name: e.name, attempts, passes: attempts.every((x) => !x.failures.length) };
  });
  return { label, words: words(text), tokens, results };
}

function main() {
  const [op, ...rest] = process.argv.slice(2);
  if (op !== "test") fail("usage: crux skill test <skill|path> [--against <ref>] [--runs <n>] [--verbose]");
  let goal = null, against = null, runs = 1, verbose = false;
  for (let i = 0; i < rest.length; i++) {
    const a = rest[i];
    if (a === "--against") against = rest[++i];
    else if (a === "--runs") runs = Math.max(1, Number(rest[++i]) || 1);
    else if (a === "--verbose") verbose = true;
    else if (a.startsWith("--")) fail(`unknown option: ${a}`);
    else goal = a;
  }
  if (!goal) fail("missing skill: crux skill test <skill|path>");
  const skill = locate(goal);
  const scenariosFile = join(dirname(skill), "tests", "escenarios.md");
  if (!existsSync(scenariosFile)) fail(`the skill has no scenarios: create ${relative(process.cwd(), scenariosFile)} (see /skill-creator)`);
  const scenarios = readScenarios(readFileSync(scenariosFile, "utf8"));
  if (!scenarios.length) fail(`${scenariosFile} has no scenario («## name»)`);

  const runner = adapter("CRUX_SKILL_RUNNER", "skill-runner.sh");
  if (!runner) fail("nobody to answer: set CRUX_SKILL_RUNNER or install the default adapter's agent");
  const tokensCmd = adapter("CRUX_SKILL_TOKENS", "skill-tokens.sh");

  const name = basename(dirname(skill));
  const current = tryOut("current", readFileSync(skill, "utf8"), scenarios, runner, tokensCmd, runs);
  const preview = against ? tryOut(against, version(skill, against), scenarios, runner, tokensCmd, runs) : null;

  const size = (v) => `${v.words} words${v.tokens ? ` · ${v.tokens} tokens` : ""}`;
  console.log(`skill ${name}: ${scenarios.length} scenarios${runs > 1 ? ` × ${runs}` : ""}`);
  console.log(`  current: ${size(current)}`);
  if (preview) {
    let delta = "";
    if (current.tokens && preview.tokens) delta = ` (${Math.round((current.tokens - preview.tokens) * 100 / preview.tokens)} % of tokens)`;
    console.log(`  ${against}: ${size(preview)}${delta}`);
  }
  console.log("");

  let failing = 0, regressions = 0;
  current.results.forEach((r, i) => {
    const before = preview?.results[i];
    const marker = r.passes ? "ok  " : (before?.passes ? "REGR" : "FAIL");
    if (!r.passes) failing++;
    if (!r.passes && before?.passes) regressions++;
    const extra = before ? `   (${against}: ${before.passes ? "ok" : "fails"})` : "";
    console.log(`${marker}  ${r.name}${extra}`);
    if (!r.passes || verbose) {
      for (const [k, it] of r.attempts.entries()) {
        if (it.failures.length) console.log(`      ${runs > 1 ? `attempt ${k + 1}: ` : ""}${it.failures.join(" · ")}`);
        if (verbose || it.failures.length) console.log(`      › ${it.answer.replace(/\s+/g, " ").slice(0, 300)}`);
      }
    }
  });
  console.log("");
  if (regressions) console.log(`${regressions} regression(s): the current version fails where ${against} passed`);
  console.log(failing ? `${failing} of ${scenarios.length} scenarios fail` : "all scenarios pass");
  process.exit(failing ? 1 : 0);
}

if (import.meta.url === `file://${process.argv[1]}`) main();
