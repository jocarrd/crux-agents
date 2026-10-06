#!/usr/bin/env node
// Tasks travel between machines: a replica of ~/.crux/tasks/<project>/ in the
// `crux/tasks` branch of the project's docs repo. See ADR-016.
//
//   node lib/task-sync.mjs sync --project <p>   pull and publish one project
//   node lib/task-sync.mjs sync --all           every one with tasks or a branch
//   node lib/task-sync.mjs pending              projects with something unpublished
//   node lib/task-sync.mjs open [--project <p>] the open tasks, as JSON
//
// The local file is the source of truth and the branch its replica. This code
// always writes it and the agent never does: with two stores and someone
// deciding each time which one wins, they drift.
//
// Only git plumbing —hash-object, write-tree, commit-tree, push—, no worktree
// or checkout: the branch never touches `main` or the docs repo's working
// tree, which may be halfway through something else.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync, spawn } from "node:child_process";
import { archive, advance, write, read, parse } from "./task.mjs";

export const BRANCH = "crux/tasks";
const REMOTE_REF = `refs/remotes/origin/${BRANCH}`;
// What the sync last saw on the remote. Its own ref, and the remote by URL and
// not by name: the sync runs in the background right after a merge, and when
// it wrote REMOTE_REF a git pull at the same moment failed with "cannot lock
// ref". By URL, neither fetch nor push touch the remote-tracking refs, and
// FETCH_HEAD, which the pull reads, is not written either.
const TRACK_REF = "refs/crux/tasks-remote";
const originUrl = (repo, push = false) =>
  git(repo, ["remote", "get-url", ...(push ? ["--push"] : []), "origin"]).trim();
const REMOVED = ".removed";
const OPEN_STATUSES = ["open", "planned", "in-progress", "verified", "proposed"];

// --- Where everything is --------------------------------------------------------

function readConfig(key) {
  const cfg = process.env.CRUX_CONFIG || path.join(os.homedir(), ".crux/config");
  try {
    const m = fs.readFileSync(cfg, "utf8").match(new RegExp(`^${key}="?([^"\\n]*)"?$`, "m"));
    return m ? m[1] : "";
  } catch {
    return "";
  }
}

export const projectsRoot = () =>
  process.env.CRUX_PROJECTS_DIR || readConfig("CRUX_PROJECTS_DIR") || path.join(os.homedir(), "Proyectos");

export const tasksDir = () =>
  process.env.CRUX_TASKS_DIR ||
  path.join(path.dirname(process.env.CRUX_REGISTRY || path.join(os.homedir(), ".crux/workspaces.json")), "tasks");

const stateDir = () =>
  path.join(process.env.CRUX_STATE_DIR || path.join(os.homedir(), ".crux/state"), "task-sync");

const isRepo = (d) => fs.existsSync(path.join(d, ".git"));

// A project's tasks travel in its docs repo; those of a standalone repo in the
// root —the kernel itself— travel in that same repo.
export function transport(project) {
  const root = projectsRoot();
  const docs = path.join(root, project, `${project}-docs`);
  if (isRepo(docs)) return docs;
  const standalone = path.join(root, project);
  if (isRepo(standalone)) return standalone;
  return null;
}

// What the contract says: false disables it, true forces it even if the repo
// is public, and with nothing the visibility decides. A contract that cannot
// be read is not taken as "no opinion": execution stops and says so.
function contractPreference(repo) {
  const f = path.join(repo, "crux.json");
  if (!fs.existsSync(f)) return undefined;
  const c = JSON.parse(fs.readFileSync(f, "utf8"));
  return c.tasks?.sync;
}

// A record carries half-formed decisions, evidence and sometimes a client's
// data: in a public repo it would be published for anyone. For GitHub the
// visibility is asked and remembered; if it cannot be known, nothing is
// published. Other remotes —a own server, a local remote— cannot be asked.
function visibility(repo) {
  // The URL as configured: get-url applies insteadOf and could hide that
  // GitHub is behind it.
  const url = attempt(() => git(repo, ["config", "--get", "remote.origin.url"]).trim()) || "";
  const m = url.match(/github\.com[:/]([^/]+\/[^/]+?)(?:\.git)?$/);
  if (!m) return "other";
  const cache = path.join(stateDir(), "visibility.json");
  const seen = attempt(() => JSON.parse(fs.readFileSync(cache, "utf8"))) || {};
  if (seen[m[1]]) return seen[m[1]];
  const v = attempt(() => execFileSync("gh", ["repo", "view", m[1], "--json", "visibility", "--jq", ".visibility"], {
    stdio: ["ignore", "pipe", "ignore"], timeout: 15000,
  }).toString().trim().toLowerCase());
  if (!v) return "unknown";
  seen[m[1]] = v;
  fs.mkdirSync(stateDir(), { recursive: true, mode: 0o700 });
  writeLocal(cache, JSON.stringify(seen));
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
      // With no terminal to answer, an ssh prompt would hang the publication.
      GIT_SSH_COMMAND: `${process.env.GIT_SSH_COMMAND || "ssh"} -o BatchMode=yes`,
      ...env,
    },
    stdio: ["pipe", "pipe", "pipe"],
    maxBuffer: 64 * 1024 * 1024,
  }).toString();
}

const attempt = (fn) => {
  try {
    return fn();
  } catch {
    return null;
  }
};

function remoteTree(repo) {
  const head = attempt(() => git(repo, ["rev-parse", "-q", "--verify", TRACK_REF]).trim());
  const files = new Map();
  if (!head) return { head: null, files };
  for (const l of git(repo, ["ls-tree", "-r", head]).split("\n").filter(Boolean)) {
    const [meta, filePath] = l.split("\t");
    files.set(filePath, meta.split(" ")[2]);
  }
  return { head, files };
}

const blob = (repo, sha) => git(repo, ["cat-file", "blob", sha]);

// --- The local side --------------------------------------------------------------------

// Conflict copies are a warning for this machine, not a task.
const isTask = (name) => name.endsWith(".md") && !name.includes(".conflicto-");

function localFiles(dir) {
  const output = [];
  for (const sub of ["", "done"]) {
    const d = path.join(dir, sub);
    if (!fs.existsSync(d)) continue;
    for (const n of fs.readdirSync(d)) {
      const filePath = sub ? `${sub}/${n}` : n;
      if (isTask(n) && fs.statSync(path.join(dir, filePath)).isFile()) output.push(filePath);
    }
  }
  return output;
}

function hashes(repo, dir, paths) {
  const m = new Map();
  if (!paths.length) return m;
  const shas = git(repo, ["hash-object", "-w", "--stdin-paths"], {
    input: paths.map((r) => path.join(dir, r)).join("\n") + "\n",
  }).trim().split("\n");
  paths.forEach((r, i) => m.set(r, shas[i]));
  return m;
}

// A removal is noted with the path and the task's creation date: with the
// path alone, a new task reusing the name of an archived one would be deleted
// on every machine as soon as it was born.
const readRemoved = (text) => new Set(text.split("\n").map((l) => l.trim()).filter(Boolean));
const created = (text) => attempt(() => parse(text).meta.created) || "";
const removalKey = (filePath, text) => `${filePath} ${created(text)}`.trim();
const isRemoved = (removed, filePath, text) =>
  removed.has(removalKey(filePath, text)) || (!created(text) && removed.has(filePath));

export function recordRemoval(projectDir, filePath, text = "") {
  fs.mkdirSync(projectDir, { recursive: true, mode: 0o700 });
  fs.appendFileSync(path.join(projectDir, REMOVED), `${removalKey(filePath, text)}\n`, { mode: 0o600 });
}

function writeLocal(file, content) {
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  const tmp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, content, { mode: 0o600 });
  fs.renameSync(tmp, file);
}

// What each file last looked like when synced: without it "I changed it" cannot
// be told from "they changed it there", and any difference would be a conflict.
const baseFile = (p) => path.join(stateDir(), `${p}.json`);
const pendingFile = (p) => path.join(stateDir(), `${p}.pending`);

function readBase(p) {
  try {
    return new Map(Object.entries(JSON.parse(fs.readFileSync(baseFile(p), "utf8"))));
  } catch {
    return new Map();
  }
}

function saveBase(p, map) {
  fs.mkdirSync(stateDir(), { recursive: true, mode: 0o700 });
  writeLocal(baseFile(p), JSON.stringify(Object.fromEntries(map), null, 1));
}

export function markPending(p) {
  fs.mkdirSync(stateDir(), { recursive: true, mode: 0o700 });
  fs.writeFileSync(pendingFile(p), new Date().toISOString(), { mode: 0o600 });
}

const updated = (text) => attempt(() => parse(text).meta.updated) || "";

// --- One project -----------------------------------------------------------------

const machine = () => os.hostname().split(".")[0].replace(/[^A-Za-z0-9-]/g, "") || "machine";

function merge(p, repo) {
  const dir = path.join(tasksDir(), p);
  const warnings = [];
  const changes = { pulled: 0, published: 0 };

  const remote = remoteTree(repo);
  const base = readBase(p);
  const locals = hashes(repo, dir, localFiles(dir));

  const localRemoved = fs.existsSync(path.join(dir, REMOVED))
    ? fs.readFileSync(path.join(dir, REMOVED), "utf8") : "";
  const remoteRemoved = remote.files.has(REMOVED) ? blob(repo, remote.files.get(REMOVED)) : "";
  const removed = new Set([...readRemoved(localRemoved), ...readRemoved(remoteRemoved)]);

  const final = new Map();
  const paths = new Set([...locals.keys(), ...remote.files.keys()]);
  paths.delete(REMOVED);

  for (const filePath of paths) {
    let L = locals.get(filePath), R = remote.files.get(filePath);
    const B = base.get(filePath);
    const local = path.join(dir, filePath);

    // Each version is looked at separately: the local one may be the task that
    // was archived and the remote one a new task with the same name. What is
    // archived is treated as if it were not there.
    if (L && isRemoved(removed, filePath, fs.readFileSync(local, "utf8"))) {
      // If it was touched here after syncing, it is saved aside.
      if (B && L !== B) {
        writeLocal(local.replace(/\.md$/, `.conflicto-${machine()}.md`), fs.readFileSync(local, "utf8"));
        warnings.push(`${p}/${filePath}: it was archived on another machine and had changes here — saved aside`);
      }
      fs.unlinkSync(local);
      L = undefined;
    }
    if (R && isRemoved(removed, filePath, blob(repo, R))) R = undefined;
    if (!L && !R) continue;

    if (L && L === R) { final.set(filePath, L); continue; }
    if (L && !R) { final.set(filePath, L); changes.published++; continue; }
    if (!L && R) {
      if (B && B === R) {
        // It was synced and no longer exists here: it was deleted by hand
        // without going through crux. That is respected and noted, so it does
        // not come back.
        removed.add(removalKey(filePath, blob(repo, R)));
        continue;
      }
      writeLocal(local, blob(repo, R));
      final.set(filePath, R);
      changes.pulled++;
      continue;
    }
    // Both exist and differ.
    if (L === B) {
      writeLocal(local, blob(repo, R));
      final.set(filePath, R);
      changes.pulled++;
    } else if (R === B) {
      final.set(filePath, L);
      changes.published++;
    } else {
      // Changed on both. The most recent wins; the other stays alongside.
      const localText = fs.readFileSync(local, "utf8"), remoteText = blob(repo, R);
      const remoteWins = updated(remoteText) > updated(localText);
      const loser = remoteWins ? localText : remoteText;
      writeLocal(local.replace(/\.md$/, `.conflicto-${remoteWins ? machine() : "remota"}.md`), loser);
      if (remoteWins) {
        writeLocal(local, remoteText);
        final.set(filePath, R);
        changes.pulled++;
      } else {
        final.set(filePath, L);
        changes.published++;
      }
      warnings.push(`${p}/${filePath}: changed on both machines — the most recent stays and the other is alongside as .conflicto-`);
    }
  }

  // What is removed travels as a list, not as an absence: an absence does not
  // distinguish "I archived it here" from "it has not reached me yet".
  const removedText = [...removed].sort().join("\n") + (removed.size ? "\n" : "");
  if (removed.size) {
    fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
    writeLocal(path.join(dir, REMOVED), removedText);
  }

  // The tree the branch should have.
  const index = path.join(os.tmpdir(), `crux-task-sync-${process.pid}-${Date.now()}`);
  const env = { GIT_INDEX_FILE: index };
  try {
    const entries = [...final.entries()];
    if (removed.size) {
      entries.push([REMOVED, git(repo, ["hash-object", "-w", "--stdin"], { input: removedText }).trim()]);
    }
    git(repo, ["read-tree", "--empty"], { env });
    if (entries.length) {
      git(repo, ["update-index", "--add", "--index-info"], {
        env,
        input: entries.map(([r, sha]) => `100644 ${sha}\t${r}`).join("\n") + "\n",
      });
    }
    const tree = git(repo, ["write-tree"], { env }).trim();
    const currentTree = remote.head ? git(repo, ["rev-parse", `${remote.head}^{tree}`]).trim() : null;
    let commit = null;
    if (tree !== currentTree && entries.length) {
      commit = git(repo, [
        // Unsigned: with commit.gpgSign on, commit-tree would ask for a key.
        "commit-tree", "--no-gpg-sign", tree, ...(remote.head ? ["-p", remote.head] : []),
        // [skip ci]: the tasks branch has nothing to check, and each
        // publication would burn CI minutes of the docs repo.
        "-m", `[skip ci] tasks: ${machine()}`,
      ], { env: { GIT_AUTHOR_NAME: "crux", GIT_AUTHOR_EMAIL: "crux@localhost",
        GIT_COMMITTER_NAME: "crux", GIT_COMMITTER_EMAIL: "crux@localhost" } }).trim();
    }
    return { commit, final, warnings, changes, removed };
  } finally {
    fs.rmSync(index, { force: true });
  }
}

// A task whose proposal was merged outside `crux merge` stayed in "proposed"
// forever, and the reminder would show it every session. Here GitHub is asked
// about those with a proposal that are not yet recorded as merged: they are
// marked, and if they have no live workspace on this machine, archived, since
// there is nothing left to resume. Without gh, nothing is touched.
function reconcile(p) {
  const dir = path.join(tasksDir(), p);
  if (!fs.existsSync(dir)) return [];
  const cache = path.join(stateDir(), "pr-state.json");
  const seen = attempt(() => JSON.parse(fs.readFileSync(cache, "utf8"))) || {};
  const liveSet = liveWorkspaces();
  const done = [];
  for (const n of fs.readdirSync(dir)) {
    if (!isTask(n)) continue;
    const f = path.join(dir, n);
    const doc = attempt(() => read(f));
    const pr = doc?.meta.pr;
    if (!pr || !["verified", "proposed"].includes(doc.meta.status)) continue;
    // An open proposal is looked at again every six hours at most.
    if (seen[pr] && Date.now() - seen[pr] < 6 * 3600000) continue;
    const status = attempt(() => execFileSync("gh", ["pr", "view", pr, "--json", "state", "--jq", ".state"], {
      stdio: ["ignore", "pipe", "ignore"], timeout: 15000,
    }).toString().trim());
    if (status === null) break;
    seen[pr] = Date.now();
    if (status !== "MERGED") continue;
    advance(doc, "merged");
    write(f, doc, { publish: false });
    const alive = (Array.isArray(doc.meta.workspaces) ? doc.meta.workspaces : []).some((e) => liveSet.has(e));
    if (!alive) attempt(() => archive(f, { publish: false }));
    done.push(`${p}/${doc.meta.task}: its proposal was already merged — ${alive ? "marked" : "archived"}`);
  }
  fs.mkdirSync(stateDir(), { recursive: true, mode: 0o700 });
  writeLocal(cache, JSON.stringify(seen));
  return done;
}

// Per-project lock: the background publication of a write and that of
// `crux sync` cannot merge at once over the same state.
function withLock(p, fn) {
  fs.mkdirSync(stateDir(), { recursive: true, mode: 0o700 });
  const lock = path.join(stateDir(), `${p}.lock`);
  for (let i = 0; ; i++) {
    try {
      fs.mkdirSync(lock);
      break;
    } catch {
      const old = attempt(() => Date.now() - fs.statSync(lock).mtimeMs > 120000);
      if (old) { fs.rmSync(lock, { recursive: true, force: true }); continue; }
      if (i > 600) throw new Error(`${p}: another task sync does not finish`);
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 100);
    }
  }
  try {
    return fn();
  } finally {
    fs.rmSync(lock, { recursive: true, force: true });
  }
}

// A single trip to the remote: each costs seconds over ssh. The fetch error
// tells a branch that does not exist yet from having no network.
function fetchBranch(repo) {
  try {
    git(repo, ["fetch", "-q", "--no-write-fetch-head", originUrl(repo), `+refs/heads/${BRANCH}:${TRACK_REF}`]);
    return "ok";
  } catch (e) {
    if (/couldn't find remote ref/i.test(String(e.stderr || ""))) {
      attempt(() => git(repo, ["update-ref", "-d", TRACK_REF]));
      return "no-branch";
    }
    return "offline";
  }
}

// `crux sync` fetches every remote by name, so what it brought is in
// REMOTE_REF: it is only read, and copied into the sync's own ref.
function adoptFetched(repo) {
  const sha = attempt(() => git(repo, ["rev-parse", "-q", "--verify", REMOTE_REF]).trim());
  attempt(() => git(repo, sha ? ["update-ref", TRACK_REF, sha] : ["update-ref", "-d", TRACK_REF]));
  return "ok";
}

export function syncProject(p, { alreadyFetched = false } = {}) {
  const repo = transport(p);
  if (!repo) return { project: p, status: "no-transport" };
  const preference = contractPreference(repo);
  const never = (status) => {
    fs.rmSync(pendingFile(p), { force: true });
    return { project: p, status };
  };
  if (preference === false) return never("disabled");
  if (!attempt(() => git(repo, ["remote", "get-url", "origin"]))) return never("no-remote");
  if (preference !== true) {
    const v = visibility(repo);
    if (v === "public") return never("public");
    if (v === "unknown") {
      markPending(p);
      return { project: p, status: "unchecked" };
    }
  }

  return withLock(p, () => {
    // Removed before starting: a write that arrives during the sync marks it
    // again and is not lost.
    fs.rmSync(pendingFile(p), { force: true });
    let last = null;
    for (let attemptNumber = 0; attemptNumber < 4; attemptNumber++) {
      // `crux sync` has just fetched every remote, tasks branch included: on
      // the first round what is there is enough. If on publishing the remote
      // turns out to have moved on, the second round does go and get it.
      const fetched = alreadyFetched && attemptNumber === 0 ? adoptFetched(repo) : fetchBranch(repo);
      if (fetched === "offline") {
        markPending(p);
        return { project: p, status: "offline" };
      }
      const hasBranch = attempt(() => git(repo, ["rev-parse", "-q", "--verify", TRACK_REF]));
      // No branch on the remote and no tasks here: nothing to do.
      if (!hasBranch && !fs.existsSync(path.join(tasksDir(), p))) {
        return { project: p, status: "ok", pulled: 0, published: 0, warnings: [] };
      }
      last = merge(p, repo);
      if (!last.commit) {
        saveBase(p, last.final);
        return { project: p, status: "ok", ...last.changes, warnings: last.warnings };
      }
      // No hooks: the branch is internal, and a docs repo pre-push —one that
      // guards the main branch, or runs tests— has nothing to say about it.
      if (attempt(() => git(repo, ["push", "-q", "--no-verify", originUrl(repo, true), `${last.commit}:refs/heads/${BRANCH}`])) !== null) {
        git(repo, ["update-ref", TRACK_REF, last.commit]);
        saveBase(p, last.final);
        return { project: p, status: "ok", ...last.changes, warnings: last.warnings };
      }
      // Another machine published in between: pull and merge again.
    }
    markPending(p);
    return { project: p, status: "rejected", warnings: last?.warnings || [] };
  });
}

// The projects that may have something to sync: those with tasks here, all
// those with a docs repo —on a machine that is arriving, their tasks exist
// only on the remote— and standalone repos whose tasks branch the `crux sync`
// fetch already brought.
export function projectsWithTasks() {
  const p = new Set();
  const dt = tasksDir();
  if (fs.existsSync(dt)) for (const n of fs.readdirSync(dt)) if (fs.statSync(path.join(dt, n)).isDirectory()) p.add(n);
  const root = projectsRoot();
  if (fs.existsSync(root)) {
    for (const n of fs.readdirSync(root)) {
      if (p.has(n) || n.includes("-ws-")) continue;
      if (isRepo(path.join(root, n, `${n}-docs`))) { p.add(n); continue; }
      const repo = transport(n);
      if (repo && [REMOTE_REF, TRACK_REF].some((r) => attempt(() => git(repo, ["rev-parse", "-q", "--verify", r])))) p.add(n);
    }
  }
  return [...p].sort();
}

// A marker whose project is no longer on this machine can never be published
// from here: kept, it made every `sync --leave` report a project that does not
// exist. It is dropped, and so is that of a repo that never publishes (public,
// disabled or without a remote), which would otherwise stay forever.
export function pendingProjects() {
  if (!fs.existsSync(stateDir())) return [];
  const out = [];
  for (const n of fs.readdirSync(stateDir())) {
    if (!n.endsWith(".pending")) continue;
    const p = n.slice(0, -8);
    if (!transport(p)) {
      fs.rmSync(path.join(stateDir(), n), { force: true });
      continue;
    }
    out.push(p);
  }
  return out.sort();
}

// The open tasks, to show them when a session starts.
export function openTasks(project) {
  const dt = tasksDir();
  if (!fs.existsSync(dt)) return [];
  const projects = project ? [project] : fs.readdirSync(dt);
  const output = [];
  for (const p of projects) {
    const dir = path.join(dt, p);
    if (!fs.existsSync(dir) || !fs.statSync(dir).isDirectory()) continue;
    for (const n of fs.readdirSync(dir)) {
      if (!isTask(n)) continue;
      const doc = attempt(() => parse(fs.readFileSync(path.join(dir, n), "utf8")));
      // A task waiting for an answer is still alive even if already merged.
      const isWaiting = Boolean(doc?.meta.waiting_on) && doc.meta.status !== "closed";
      if (!doc || (!OPEN_STATUSES.includes(doc.meta.status) && !isWaiting)) continue;
      const sec = (t) => (doc.sections.find((s) => s.title === t)?.lines.join("\n") || "")
        .replace(/<!--[\s\S]*?-->/g, "").trim().split("\n")[0];
      output.push({
        project: p,
        task: doc.meta.task || n.slice(0, -3),
        status: doc.meta.status,
        updated: doc.meta.updated || "",
        next: sec("Next step") || sec("Objective"),
        workspaces: Array.isArray(doc.meta.workspaces) ? doc.meta.workspaces : [],
        waiting: isWaiting
          ? { on: doc.meta.waiting_on, ask: doc.meta.waiting_ask || "", since: doc.meta.waiting_since || "", ref: doc.meta.waiting_ref || "" }
          : null,
      });
    }
  }
  return output.sort((a, b) => (b.updated > a.updated ? 1 : -1));
}

// --- The reminder ------------------------------------------------------------------
//
// When a session starts or resumes, the open tasks are shown. It is a reminder
// and nothing more: the person decides whether to resume any, and if they ask
// for something else, something else is done. That is why there are two texts:
// one the person sees as is, and another for the agent that expressly says not
// to push them.

function projectOf(cwd) {
  const root = path.resolve(projectsRoot());
  const rel = path.relative(root, path.resolve(cwd || "."));
  if (!rel || rel.startsWith("..") || path.isAbsolute(rel)) return null;
  return rel.split(path.sep)[0].replace(/-ws-.*$/, "");
}

function liveWorkspaces() {
  const f = process.env.CRUX_REGISTRY || path.join(os.homedir(), ".crux/workspaces.json");
  const liveSet = new Set();
  const r = attempt(() => JSON.parse(fs.readFileSync(f, "utf8")));
  for (const [n, w] of Object.entries(r?.workspaces || {})) if (w.path && fs.existsSync(w.path)) liveSet.add(n);
  return liveSet;
}

const ago = (date) => {
  const t = Date.parse(date);
  if (Number.isNaN(t)) return "";
  const d = Math.floor((Date.now() - t) / 86400000);
  return d <= 0 ? "today" : d === 1 ? "yesterday" : `${d} days ago`;
};

const daysSince = (isoDate) => {
  const t = Date.parse(isoDate);
  return Number.isNaN(t) ? null : Math.max(0, Math.floor((Date.now() - t) / 86400000));
};

// After how many days of waiting a nudge is suggested.
const nudgeAfterDays = () => {
  const n = Number(process.env.CRUX_WAIT_NUDGE_DAYS);
  return Number.isFinite(n) && n > 0 ? n : 7;
};

export function reminder(cwd, maximum = 6) {
  const project = projectOf(cwd);
  let list = openTasks(project && fs.existsSync(path.join(tasksDir(), project)) ? project : undefined);
  if (!list.length) return null;
  const liveSet = liveWorkspaces();
  const truncate = (t, n) => (t.length > n ? `${t.slice(0, n - 1)}…` : t);
  // The same data as the text, for whoever draws it another way (the Claude
  // Code mod renders it as a panel).
  // First the work that depends on us; then what waits on someone else.
  list = [...list.filter((t) => !t.waiting), ...list.filter((t) => t.waiting)];
  const nudgeDays = nudgeAfterDays();
  const tasks = list.slice(0, maximum).map((t) => ({
    task: `${t.project}/${t.task}`,
    name: t.task,
    status: t.waiting ? "waiting" : t.status,
    when: ago(t.updated),
    next: t.waiting ? t.waiting.ask : t.next || "",
    here: t.workspaces.some((e) => liveSet.has(e)),
    waiting: t.waiting
      ? { ...t.waiting, days: daysSince(t.waiting.since), nudge: (daysSince(t.waiting.since) ?? 0) >= nudgeDays }
      : null,
  }));
  const lines = [];
  let waitingBlock = false;
  for (const t of list.slice(0, maximum)) {
    // One line per task: the phone remote control renders each line as a separate notice
    if (t.waiting) {
      if (!waitingBlock) { lines.push("Waiting for an answer:"); waitingBlock = true; }
      const days = daysSince(t.waiting.since);
      const since = t.waiting.since ? ago(t.waiting.since) : "";
      lines.push(`· ${t.project}/${t.task} · to ${t.waiting.on}${since ? `, ${since}` : ""}` +
        (t.waiting.ask ? `: ${truncate(t.waiting.ask, 70)}` : "") +
        ((days ?? 0) >= nudgeDays ? " · worth a nudge" : ""));
      continue;
    }
    const here = t.workspaces.some((e) => liveSet.has(e));
    const status = t.status === "open" ? "" : `${t.status}, `;
    lines.push(`· ${t.project}/${t.task} (${status}${ago(t.updated)})` +
      (t.next ? `: ${truncate(t.next, 70)}` : "") +
      (here ? "" : ` · no workspace here: crux workspace resume ${t.task}`));
  }
  if (list.length > maximum) lines.push(`· and ${list.length - maximum} more: crux status`);
  const conflicts = [];
  for (const p of new Set(list.map((t) => t.project))) {
    const dir = path.join(tasksDir(), p);
    for (const n of attempt(() => fs.readdirSync(dir)) || []) if (n.includes(".conflicto-")) conflicts.push(path.join(dir, n));
  }
  if (conflicts.length) {
    lines.push(`· ${conflicts.length === 1 ? "there is 1 copy" : `there are ${conflicts.length} copies`} of a conflict between machines to review: ${path.dirname(conflicts[0])}`);
  }
  const title = project && list.every((t) => t.project === project)
    ? `Open tasks in ${project}` : "Open tasks";
  const user = `${title}, in case you want to resume one:\n${lines.join("\n")}`;
  const agent = [
    `${title} of this person (already shown to them):`,
    ...lines,
    "",
    "This is only a reminder. Do not resume any or propose one on your own, and do not push:",
    "if they ask for something else, do that something else. If they decide to resume one that has",
    "no workspace on this computer, it is opened with `crux workspace resume <task>`.",
    ...(waitingBlock
      ? ["The ones waiting for an answer depend on another person: do not resume them until it arrives,", "and if a nudge is due, say so once and let the person decide."]
      : []),
  ].join("\n");
  return { user, agent, title, tasks, more: Math.max(0, list.length - maximum), conflicts: conflicts.length };
}

// After each write: publish without making the writer wait. The pending mark
// goes first, in the same process, so that if this never gets to run —offline,
// powered off— `crux sync --leave` knows.
export function publishInBackground(file) {
  if (process.env.CRUX_IN_TESTS === "1" && process.env.CRUX_TASK_SYNC !== "1") return;
  if (process.env.CRUX_TASK_SYNC === "0") return;
  let dir = path.dirname(file);
  if (path.basename(dir) === "done") dir = path.dirname(dir);
  if (path.dirname(dir) !== path.resolve(tasksDir())) return;
  const p = path.basename(dir);
  attempt(() => markPending(p));
  attempt(() => {
    const child = spawn(process.execPath, [new URL(import.meta.url).pathname, "sync", "--project", p], {
      detached: true,
      stdio: "ignore",
    });
    child.unref();
  });
}

// --- Command line --------------------------------------------------------------

function main() {
  const [op, ...rest] = process.argv.slice(2);
  const value = (k) => {
    const i = rest.indexOf(`--${k}`);
    return i >= 0 ? rest[i + 1] : undefined;
  };
  switch (op) {
    case "sync": {
      const list = rest.includes("--all") ? projectsWithTasks() : [value("project")].filter(Boolean);
      if (!list.length && !rest.includes("--all")) throw new Error("missing --project or --all");
      const r = list.map((p) => {
        try {
          // Only in full rounds: the publication after each write has to be
          // fast and talk to nobody but git.
          // Pulling comes first: what has to be reconciled may come from the
          // other machine. If something is closed, it is published again.
          const options = { alreadyFetched: rest.includes("--fetched") };
          let s = syncProject(p, options);
          const closed = rest.includes("--all") && s.status === "ok" ? reconcile(p) : [];
          if (closed.length) {
            const before = s;
            s = syncProject(p, options);
            s.pulled = before.pulled;
            s.warnings = [...(before.warnings || []), ...(s.warnings || [])];
            s.closed = closed;
          }
          return s;
        } catch (e) {
          return { project: p, status: "failed", reason: String(e.message || e).split("\n")[0] };
        }
      });
      console.log(JSON.stringify(r));
      break;
    }
    case "projects":
      console.log(projectsWithTasks().join("\n"));
      break;
    case "pending":
      console.log(pendingProjects().join("\n"));
      break;
    case "open":
      console.log(JSON.stringify(openTasks(value("project"))));
      break;
    case "remind": {
      const r = reminder(value("cwd") || process.cwd());
      if (r) console.log(JSON.stringify(r));
      break;
    }
    default:
      throw new Error(`unknown operation: ${op}`);
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
