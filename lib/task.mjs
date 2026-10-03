#!/usr/bin/env node
// A task record: one markdown file with a header per task.
//
//   node lib/task.mjs <operation> --file <path> [options]
//
// The commands write it, not the agent by hand: a checkbox or a status that
// depends on someone remembering to edit a file ends up lying, and a record
// that lies is worse than none. See ADR-012.
//
// A single file is the source of truth. Its replica in the docs repo, so the
// task carries on in another machine, is always written by lib/task-sync.mjs
// from it, never by hand. See ADR-016.

import fs from "node:fs";
import path from "node:path";
import { recordRemoval, publishInBackground } from "./task-sync.mjs";

export const STATUSES = ["open", "planned", "in-progress", "verified", "proposed", "merged", "deployed", "closed"];

// The order of the sections follows the life of the task: what is wanted, what
// is done, what is decided along the way and what was checked.
export const SECTIONS = [
  ["Objective", "One sentence: what is to be achieved and why."],
  ["Scope", "What is in and what stays out."],
  ["Plan", "Only if the task needs it: what changes, the trace, what breaks, alternatives and doubts."],
  ["Steps", ""],
  ["Next step", ""],
  ["Deviations and decisions", "What came out different from the plan and what was decided with the code in front."],
  ["Verification", ""],
  ["Closure", ""],
];

// Records written before the headings went English carry the Spanish ones:
// they are read as their English equivalent and rewritten in English.
const LEGACY_HEADINGS = {
  "Objetivo": "Objective",
  "Alcance": "Scope",
  "Pasos": "Steps",
  "Siguiente paso": "Next step",
  "Desviaciones y decisiones": "Deviations and decisions",
  "Verificación": "Verification",
  "Verificacion": "Verification",
  "Cierre": "Closure",
};
const canonical = (title) => LEGACY_HEADINGS[title] || title;

const now = () => {
  const d = new Date();
  const p = (n) => String(n).padStart(2, "0");
  // With seconds: the creation date identifies an archived task, and two tasks
  // with the same name created in the same minute used to get mixed up.
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
};

// --- Reading and writing --------------------------------------------------------

export function parse(text) {
  const m = text.match(/^---\n([\s\S]*?)\n---\n?/);
  if (!m) throw new Error("the record has no header");
  const meta = {};
  for (const line of m[1].split("\n")) {
    // Any key, not just single-word lowercase ones: the others were wiped on
    // the first automatic write.
    const kv = line.match(/^([A-Za-z][A-Za-z0-9_-]*):\s*(.*)$/);
    if (!kv) continue;
    const v = kv[2].trim();
    meta[kv[1]] = v.startsWith("[") ? v.slice(1, -1).split(",").map((s) => s.trim()).filter(Boolean) : v;
  }
  const sections = [];
  // What sits between the header and the first `## ` also belongs to the
  // document: a hand-written context paragraph vanished on rewrite.
  const preamble = [];
  let current = null;
  // A `## ` inside a code block is text, not a heading. Splitting there put
  // what follows inside the block and left the rest hanging off a phantom
  // section, and the proposal body came out truncated.
  let inCode = false;
  for (const line of text.slice(m[0].length).split("\n")) {
    if (/^\s*(```|~~~)/.test(line)) inCode = !inCode;
    const h = inCode ? null : line.match(/^## (.+)$/);
    if (h) {
      current = { title: canonical(h[1].trim()), lines: [] };
      sections.push(current);
    } else if (current) {
      current.lines.push(line);
    } else {
      preamble.push(line);
    }
  }
  while (preamble.length && preamble[preamble.length - 1].trim() === "") preamble.pop();
  while (preamble.length && preamble[0].trim() === "") preamble.shift();
  return { meta, sections, preamble };
}

export function render({ meta, sections, preamble = [] }) {
  const order = ["task", "project", "status", "repos", "workspaces", "branches", "created", "updated", "pr"];
  const keys = [...order.filter((k) => k in meta), ...Object.keys(meta).filter((k) => !order.includes(k))];
  const header = keys
    .map((k) => `${k}: ${Array.isArray(meta[k]) ? `[${meta[k].join(", ")}]` : meta[k]}`)
    .join("\n");
  const body = sections
    .map((s) => {
      const lines = [...s.lines];
      while (lines.length && lines[lines.length - 1].trim() === "") lines.pop();
      while (lines.length && lines[0].trim() === "") lines.shift();
      return `## ${s.title}\n\n${lines.join("\n")}${lines.length ? "\n" : ""}`;
    })
    .join("\n");
  const previous = preamble.length ? `${preamble.join("\n")}\n\n` : "";
  return `---\n${header}\n---\n\n${previous}${body}`;
}

export function read(file) {
  if (!fs.existsSync(file)) throw new Error(`the record ${file} does not exist`);
  return parse(fs.readFileSync(file, "utf8"));
}

export function write(file, doc, { publish = true } = {}) {
  doc.meta.updated = now();
  // 700 and 600: the record holds the objective, decisions and evidence of
  // tasks for different clients, and with the usual umask it was readable by
  // anyone on the machine.
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  const tmp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, render(doc), { mode: 0o600 });
  fs.renameSync(tmp, file);
  if (publish) publishInBackground(file);
}

// Trailing blank lines in a section are formatting, not content: if they
// stay, each new step shows up separated from the previous one.
const truncate = (s) => {
  while (s.lines.length && s.lines[s.lines.length - 1].trim() === "") s.lines.pop();
  return s;
};

const section = (doc, title) => {
  const name = canonical(title);
  let s = doc.sections.find((x) => x.title === name);
  if (!s) {
    s = { title: name, lines: [] };
    doc.sections.push(s);
  }
  return s;
};

// A section with only its help comment is empty.
const content = (s) =>
  (s ? s.lines.join("\n") : "").replace(/<!--[\s\S]*?-->/g, "").trim();

export function steps(doc) {
  const s = doc.sections.find((x) => x.title === "Steps");
  return (s ? s.lines : [])
    .map((l) => l.match(/^- \[( |x)\] (T\d+) (.*)$/))
    .filter(Boolean)
    .map(([, marker, id, rest]) => ({ id, done: marker === "x", text: rest }));
}

// Statuses only advance on their own. Going back is a decision and is asked
// for with `crux task status`: a repeated seal cannot return something already
// merged to "verified".
export function advance(doc, status) {
  const current = STATUSES.indexOf(doc.meta.status);
  if (STATUSES.indexOf(status) > current) doc.meta.status = status;
}

// --- Waiting -----------------------------------------------------------------------
//
// Waiting on someone is not one more step in the life of the task: a task can
// be merged and still pending an answer. That is why it has its own field and
// is not part of STATUSES, which only advance. See ADR-017.

const oneLine = (t) => String(t || "").replace(/\s+/g, " ").trim().replace(/^\[/, "(").replace(/\]$/, ")");

export function setWaiting(doc, { on, ask, ref, since }) {
  if (!oneLine(on)) throw new Error("missing who is being waited on: --on \"<who>\"");
  if (!oneLine(ask)) throw new Error("missing what was asked: --ask \"<what>\"");
  doc.meta.waiting_on = oneLine(on);
  doc.meta.waiting_ask = oneLine(ask);
  doc.meta.waiting_since = since || doc.meta.waiting_since || now().slice(0, 10);
  if (oneLine(ref)) doc.meta.waiting_ref = oneLine(ref);
  else delete doc.meta.waiting_ref;
}

export function clearWaiting(doc) {
  const hadWaiting = Boolean(doc.meta.waiting_on);
  for (const k of ["waiting_on", "waiting_ask", "waiting_since", "waiting_ref"]) delete doc.meta[k];
  return hadWaiting;
}

export function waitingOf(doc) {
  if (!doc.meta.waiting_on) return null;
  return {
    on: doc.meta.waiting_on,
    ask: doc.meta.waiting_ask || "",
    since: doc.meta.waiting_since || "",
    ref: doc.meta.waiting_ref || "",
  };
}

// A branch deleted when the task goes into waiting is not a lost branch: it is
// noted as retired so that `workspace resume` opens a new one from the main
// branch instead of reporting it missing.
export function retireBranch(doc, { repo, branch, workspace }) {
  const asList = (v) => (Array.isArray(v) ? v : v ? [v] : []);
  doc.meta.retired = [...asList(doc.meta.retired).filter((e) => !e.startsWith(`${repo}=`)), `${repo}=${branch}`];
  doc.meta.branches = asList(doc.meta.branches).filter((e) => !e.startsWith(`${repo}=`));
  if (workspace) doc.meta.workspaces = asList(doc.meta.workspaces).filter((w) => w !== workspace);
}

export function reopenBranch(doc, repo) {
  const asList = (v) => (Array.isArray(v) ? v : v ? [v] : []);
  doc.meta.retired = asList(doc.meta.retired).filter((e) => !e.startsWith(`${repo}=`));
  if (!doc.meta.retired.length) delete doc.meta.retired;
}

// --- Operations ----------------------------------------------------------------

export function create({ task, project, repo, workspace }) {
  const today = now();
  return {
    meta: {
      task,
      project,
      status: "open",
      repos: repo ? [repo] : [],
      workspaces: workspace ? [workspace] : [],
      created: today,
      updated: today,
    },
    sections: SECTIONS.map(([title, help]) => ({ title, lines: help ? [`<!-- ${help} -->`] : [] })),
  };
}

export function join(doc, { repo, workspace }) {
  for (const [key, value] of [["repos", repo], ["workspaces", workspace]]) {
    if (!value) continue;
    const list = Array.isArray(doc.meta[key]) ? doc.meta[key] : [];
    if (!list.includes(value)) list.push(value);
    doc.meta[key] = list;
  }
}

export function setSection(doc, title, text) {
  section(doc, title).lines = text.split("\n");
}

export function append(doc, title, text) {
  const s = truncate(section(doc, title));
  s.lines = s.lines.filter((l) => !/^<!--.*-->$/.test(l.trim()));
  s.lines.push(`- ${text}`);
}

// A decision carries its why, and optionally where it lives and what was
// learned. It goes on a single line so the record stays a list.
export function decisionLine({ what, why, where, learned }) {
  return [what, why && `Why: ${why}`, where && `Where: ${where}`, learned && `Learned: ${learned}`]
    .filter(Boolean)
    .join(" · ");
}

// Notes with a why are decisions: they are the ones that have to outlast the
// task. The rest are deviations from the plan and stay in the record.
export function decisions(doc) {
  return content(doc.sections.find((x) => x.title === "Deviations and decisions"))
    .split("\n")
    .filter((l) => l.startsWith("- ") && l.includes(" · Why: "))
    .map((l) => {
      const [what, ...fields] = l.slice(2).split(" · ");
      const d = { what };
      for (const c of fields) {
        const m = c.match(/^(Why|Where|Learned): (.*)$/);
        if (m) d[m[1].toLowerCase()] = m[2];
      }
      return d;
    });
}

export function addStep(doc, text) {
  const s = truncate(section(doc, "Steps"));
  const n = steps(doc).reduce((max, p) => Math.max(max, Number(p.id.slice(1))), 0) + 1;
  s.lines.push(`- [ ] T${n} ${text}`);
  return `T${n}`;
}

export function complete(doc, id, evidence) {
  const s = section(doc, "Steps");
  const i = s.lines.findIndex((l) => new RegExp(`^- \\[( |x)\\] ${id} `).test(l));
  if (i < 0) throw new Error(`there is no step ${id}`);
  let line = s.lines[i].replace(/^- \[ \]/, "- [x]");
  if (evidence) line = `${line.replace(/ · (?:evidencia|evidence): .*$/, "")} · evidence: ${evidence}`;
  s.lines[i] = line;
  advance(doc, "in-progress");
}

// The gate receipt is the evidence of what was checked: it is dumped as is,
// without summarising, because summarising is where what was not run sneaks in.
export function verify(doc, receipt, sha) {
  const runs = receipt
    .split("\n")
    .map((l) => l.match(/^run (\S+) (\S+) (.*)$/))
    .filter(Boolean)
    .map(([, rc, seconds, cmd]) => `- ${rc === "0" ? "ok" : `exit ${rc}`} · ${cmd} (${seconds}s)`);
  setSection(doc, "Verification", [`On ${sha.slice(0, 8)}:`, "", ...runs].join("\n"));
  advance(doc, "verified");
}

export function summary(doc) {
  const ps = steps(doc);
  const doneCount = ps.filter((p) => p.done).length;
  const next = content(doc.sections.find((x) => x.title === "Next step")).split("\n")[0];
  const pending = ps.find((p) => !p.done);
  return {
    task: doc.meta.task,
    status: doc.meta.status,
    steps: ps.length ? `${doneCount}/${ps.length}` : "",
    next: next || (pending ? `${pending.id} ${pending.text}` : ""),
    objective: content(doc.sections.find((x) => x.title === "Objective")).split("\n")[0],
    waiting: waitingOf(doc),
  };
}

// The proposal description comes from the record but does not quote it: in a
// client's repo we do not show how we work inside. Only what changes, what was
// decided and what was checked.
export function proposalBody(doc, language = "en") {
  // The machine path is stripped from the whole body. It used to happen only
  // in "Verification", and each step's evidence field, where absolute paths
  // are pasted most, came out raw.
  const withoutPaths = (t) => {
    const matches = process.env.HOME;
    let v = matches ? String(t).split(matches).join("~") : String(t);
    return v.replace(/\/(home|Users)\/[A-Za-z0-9._-]+/g, "~");
  };
  const t = language === "es"
    ? { changes: "Qué cambia", scope: "Alcance", steps: "Hecho", decisions: "Decisiones", checked: "Comprobado" }
    : { changes: "What changes", scope: "Scope", steps: "Done", decisions: "Decisions", checked: "Checked" };
  const block = (title, text) => (text ? `## ${title}\n\n${text}\n` : "");
  const sec = (title) => content(doc.sections.find((x) => x.title === title));
  const doneCount = steps(doc)
    .filter((p) => p.done)
    // The evidence goes in parentheses and without the label: the label is in
    // the record's language, and the description may be in another.
    .map((p) => `- ${p.text.replace(/ · (?:evidencia|evidence): (.*)$/, " ($1)")}`)
    .join("\n");
  const checked = sec("Verification")
    .split("\n")
    .filter((l) => l.startsWith("- "))
    .join("\n");
  return [
    block(t.changes, withoutPaths(sec("Objective"))),
    block(t.scope, withoutPaths(sec("Scope"))),
    block(t.steps, withoutPaths(doneCount)),
    block(t.decisions, withoutPaths(sec("Deviations and decisions"))),
    block(t.checked, withoutPaths(checked)),
  ]
    .filter(Boolean)
    .join("\n");
}

// Archiving is closing and setting aside: the record stops showing in lists
// but is kept, dated, until it expires. What had to last already went to the
// proposal and the docs repo.
export function archive(file, { publish = true } = {}) {
  const doc = read(file);
  const today = now().slice(0, 10);
  doc.meta.status = "closed";
  setSection(doc, "Closure", `closed ${today}`);
  const target = path.join(path.dirname(file), "done", `${today}-${path.basename(file)}`);
  if (fs.existsSync(target)) throw new Error(`a file with that name already exists: ${target}`);
  write(target, doc, { publish: false });
  fs.unlinkSync(file);
  // Without noting it, the other machine would upload the task as open again:
  // an absence does not distinguish "archived here" from "not arrived yet".
  recordRemoval(path.dirname(file), path.basename(file), render(doc));
  if (publish) publishInBackground(target);
  return target;
}

// --- Command line ------------------------------------------------------------

function options(argv) {
  const o = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i].startsWith("--")) {
      const key = argv[i].slice(2);
      const next = argv[i + 1];
      if (next === undefined || next.startsWith("--")) o[key] = true;
      else o[key] = argv[++i];
    } else o._.push(argv[i]);
  }
  return o;
}

function main() {
  const [op, ...rest] = process.argv.slice(2);
  const o = options(rest);
  const file = o.file;
  if (!file) throw new Error("missing --file");

  const mutate = (fn) => {
    const doc = read(file);
    const output = fn(doc);
    write(file, doc);
    return output;
  };

  switch (op) {
    case "ensure": {
      if (fs.existsSync(file)) {
        mutate((doc) => join(doc, { repo: o.repo, workspace: o.workspace }));
        console.log("joined");
      } else {
        write(file, create({ task: o.task, project: o.project, repo: o.repo, workspace: o.workspace }));
        console.log("created");
      }
      break;
    }
    case "set":
      mutate((doc) => setSection(doc, o.section, o.text));
      break;
    case "note":
      mutate((doc) => append(doc, "Deviations and decisions",
        decisionLine({ what: o.text, why: o.why, where: o.where, learned: o.learned })));
      break;
    case "decisions": {
      const doc = read(file);
      console.log(JSON.stringify({ task: doc.meta.task, repos: doc.meta.repos || [], items: decisions(doc) }));
      break;
    }
    case "add":
      console.log(mutate((doc) => addStep(doc, o.text)));
      break;
    case "done":
      mutate((doc) => complete(doc, o.id, o.evidence === true ? "" : o.evidence));
      break;
    case "status": {
      if (!STATUSES.includes(o.to)) throw new Error(`unknown status: ${o.to} — valid: ${STATUSES.join(", ")}`);
      mutate((doc) => (o.force ? (doc.meta.status = o.to) : advance(doc, o.to)));
      break;
    }
    case "wait":
      mutate((doc) => setWaiting(doc, { on: o.on, ask: o.ask, ref: o.ref === true ? "" : o.ref }));
      break;
    case "unwait":
      console.log(mutate((doc) => clearWaiting(doc)) ? "cleared" : "none");
      break;
    case "waiting": {
      const w = waitingOf(read(file));
      if (w) console.log([w.on, w.ask, w.since, w.ref].join("\x1f"));
      break;
    }
    case "retire":
      mutate((doc) => retireBranch(doc, { repo: o.repo, branch: o.branch, workspace: o.workspace === true ? "" : o.workspace }));
      break;
    case "reopen":
      mutate((doc) => reopenBranch(doc, o.repo));
      break;
    case "retired": {
      const m = read(file).meta;
      for (const entry of Array.isArray(m.retired) ? m.retired : m.retired ? [m.retired] : []) console.log(entry.replace("=", "\t"));
      break;
    }
    case "meta":
      mutate((doc) => (doc.meta[o.key] = o.value));
      break;
    case "places": {
      // Where the task lives: repo, branch and workspace per line. Read by `resume`.
      const m = read(file).meta;
      const list = (v) => (Array.isArray(v) ? v : []);
      const branches = Object.fromEntries(list(m.branches).map((e) => e.split("=")));
      list(m.repos).forEach((r, i) => console.log([r, branches[r] || "", list(m.workspaces)[i] || ""].join("\t")));
      break;
    }
    case "branch":
      // Each repo's branch, as repo=branch: what another machine needs to open
      // the same workspace from the remote.
      mutate((doc) => {
        const list = (Array.isArray(doc.meta.branches) ? doc.meta.branches : [])
          .filter((e) => !e.startsWith(`${o.repo}=`));
        list.push(`${o.repo}=${o.branch}`);
        doc.meta.branches = list;
      });
      break;
    case "verify":
      mutate((doc) => verify(doc, fs.readFileSync(o.receipt, "utf8"), o.sha));
      break;
    case "summary": {
      const r = summary(read(file));
      if (o.json) console.log(JSON.stringify(r));
      // Unit separator and not tab: to the shell a tab is whitespace, and two in
      // a row —a task without steps— merge into one and shift the fields.
      else console.log([r.task, r.status, r.steps, r.next].join("\x1f"));
      break;
    }
    case "archive":
      console.log(archive(file));
      break;
    case "body":
      process.stdout.write(proposalBody(read(file), o.lang));
      break;
    default:
      throw new Error(`unknown operation: ${op}`);
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
