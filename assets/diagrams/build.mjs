// Generates the README diagrams: the SVG source and a PNG at twice the size,
// which is what the README shows.
//
//   node assets/diagrams/build.mjs
//
// The PNG needs playwright-core and a Chrome; without them only the SVG is
// written, and the run says so.
import { writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const OUT = dirname(fileURLToPath(import.meta.url));

const THEME = { bg: "#0d1117", panel: "#161b22", edge: "#30363d", text: "#e6edf3", mute: "#9198a1", accent: "#22d3ee", accentSoft: "#0b3a44", warn: "#fb923c", warnSoft: "#3a1d0c" };

const SANS = "-apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif";
const MONO = "ui-monospace, SFMono-Regular, Menlo, Consolas, monospace";
const esc = (s) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

function svg(w, h, t, body) {
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${w} ${h}" width="${w}" height="${h}" font-family="${SANS}">
<defs><marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="${t.mute}"/></marker>
<marker id="arrowA" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="${t.accent}"/></marker></defs>
<rect width="${w}" height="${h}" rx="16" fill="${t.bg}"/>
${body}
</svg>
`;
}

const text = (t, x, y, s, { size = 15, weight = 400, color = t.text, anchor = "start", mono = false } = {}) =>
  `<text x="${x}" y="${y}" font-size="${size}" font-weight="${weight}" fill="${color}" text-anchor="${anchor}"${mono ? ` font-family="${MONO}" xml:space="preserve"` : ""}>${esc(s)}</text>`;
const box = (t, x, y, w, h, { fill = t.panel, stroke = t.edge, r = 12, dash = false } = {}) =>
  `<rect x="${x}" y="${y}" width="${w}" height="${h}" rx="${r}" fill="${fill}" stroke="${stroke}" stroke-width="1.5"${dash ? ' stroke-dasharray="6 5"' : ""}/>`;
const line = (t, x1, y1, x2, y2, { color = t.mute, accent = false, dash = false } = {}) =>
  `<path d="M${x1},${y1} L${x2},${y2}" stroke="${accent ? t.accent : color}" stroke-width="2" fill="none" marker-end="url(#${accent ? "arrowA" : "arrow"})"${dash ? ' stroke-dasharray="5 5"' : ""}/>`;
const path = (t, d, { accent = false, dash = false } = {}) =>
  `<path d="${d}" stroke="${accent ? t.accent : t.mute}" stroke-width="2" fill="none" marker-end="url(#${accent ? "arrowA" : "arrow"})"${dash ? ' stroke-dasharray="5 5"' : ""}/>`;
const dot = (t, x, y, c = t.accent) => `<circle cx="${x}" cy="${y}" r="5" fill="${c}"/>`;

function lines(t, x, y, items, opts = {}) {
  return items.map((s, i) => text(t, x, y + i * (opts.gap || 22), s, opts)).join("\n");
}

// 1. Where each kind of memory lives
function memory(t) {
  const W = 1200, H = 660;
  let b = "";
  b += text(t, 40, 52, "Where each kind of memory lives", { size: 24, weight: 700 });
  b += text(t, 40, 80, "Three repos on your git remote, each owned by a different thing. Nothing important stays on one machine.", { size: 15, color: t.mute });

  b += box(t, 30, 104, W - 60, 268, { fill: "none", stroke: t.edge, dash: true });
  b += text(t, 52, 132, "YOUR GIT REMOTE", { size: 13, weight: 700, color: t.mute });

  const cols = [
    { x: 52, title: "The project", repo: "<project>-docs", who: "one per project", items: ["decisions (ADRs)", "conventions and runbooks", "notes per code repo", "tasks, on the crux/tasks branch"] },
    { x: 428, title: "You", repo: "agent-profile", who: "one per person", items: ["how you want agents to work", "who you are and your plans", "what only holds on one machine", "loaded by every agent you use"] },
    { x: 804, title: "The rules", repo: "crux", who: "this repo", items: ["the standard every project meets", "cross-cutting skills", "hooks that block what skips the method", "templates and commands"] },
  ];
  for (const c of cols) {
    b += box(t, c.x, 148, 344, 206);
    b += dot(t, c.x + 26, 178);
    b += text(t, c.x + 42, 184, c.title, { size: 20, weight: 700 });
    b += text(t, c.x + 24, 212, c.repo, { size: 15, weight: 700, color: t.accent, mono: true });
    b += text(t, c.x + 320, 184, c.who, { size: 13, color: t.mute, anchor: "end" });
    b += lines(t, c.x + 24, 246, c.items.map((s) => "· " + s), { size: 15, gap: 25 });
  }

  b += box(t, 30, 420, W - 60, 214, { fill: "none", stroke: t.edge, dash: true });
  b += text(t, 52, 448, "EACH MACHINE", { size: 13, weight: 700, color: t.mute });

  b += box(t, 52, 466, 520, 148);
  b += text(t, 76, 498, "~/Proyectos/<project>/", { size: 15, weight: 700, mono: true });
  b += lines(t, 76, 530, ["<project>-docs/    the docs repo", "<repo>/            code, with AGENTS.md", "                   pointing to the docs", "<repo>-ws-<task>/  one worktree per task"], { size: 14, gap: 21, mono: true, color: t.mute });

  b += box(t, 600, 466, 270, 148, { fill: t.accentSoft, stroke: t.accent });
  b += text(t, 624, 498, "Your agent", { size: 17, weight: 700 });
  b += lines(t, 624, 528, ["Claude Code or Codex", "skills as /<name>", "hooks on every action", "profile + project context"], { size: 14, gap: 21, color: t.text });

  b += box(t, 898, 466, 250, 148);
  b += text(t, 922, 498, "~/.crux/", { size: 15, weight: 700, mono: true });
  b += lines(t, 922, 530, ["kernel/<version>/", "tasks/<project>/", "config"], { size: 14, gap: 21, mono: true, color: t.mute });

  b += line(t, 224, 356, 224, 462, { accent: true });
  b += text(t, 236, 414, "crux clone · crux sync", { size: 13, color: t.mute, mono: true });
  b += line(t, 600, 356, 735, 462, { accent: true });
  b += text(t, 682, 404, "crux profile link", { size: 13, color: t.mute, mono: true });
  b += line(t, 976, 356, 1023, 462, { accent: true });
  b += text(t, 1012, 404, "install.sh", { size: 13, color: t.mute, mono: true });
  return svg(W, H, t, b);
}

// 2. A task's life
function cycle(t) {
  const W = 1200, H = 650;
  let b = "";
  b += text(t, 40, 52, "A task, from start to merge", { size: 24, weight: 700 });
  b += text(t, 40, 80, "Every development task enters through its own space and leaves as a reviewed proposal.", { size: 15, color: t.mute });

  const steps = [
    { title: "workspace new", sub: ["branch, worktree,", "ports, task record"] },
    { title: "develop", sub: ["crux task add / done", "steps with evidence"] },
    { title: "/ship", sub: ["the author's gate:", "tests, diff, receipt"], gate: true },
    { title: "workspace finish", sub: ["pushes, opens the", "proposal from the task"] },
    { title: "checks + /review-pr", sub: ["CI, then an", "independent review"], gate: true },
    { title: "merge + rm", sub: ["decisions go to the", "docs repo, task archived"] },
  ];
  const bw = 168, gap = 22, y = 130, x0 = 40;
  steps.forEach((s, i) => {
    const x = x0 + i * (bw + gap);
    b += box(t, x, y, bw, 118, s.gate ? { fill: t.accentSoft, stroke: t.accent } : {});
    b += text(t, x + 16, y + 34, s.title, { size: 15, weight: 700, mono: !s.gate || s.title.startsWith("/") });
    b += lines(t, x + 16, y + 66, s.sub, { size: 13, gap: 20, color: t.mute });
    if (i < steps.length - 1) b += line(t, x + bw + 2, y + 59, x + bw + gap - 2, y + 59, { accent: true });
  });
  const dev = x0 + bw + gap + bw / 2;
  const ship = x0 + 2 * (bw + gap) + bw / 2, review = x0 + 4 * (bw + gap) + bw / 2;
  b += path(t, `M${ship},${y + 118} C${ship},${y + 168} ${dev + 24},${y + 168} ${dev + 24},${y + 122}`, { dash: true });
  b += text(t, (ship + dev) / 2 + 4, y + 148, "/ship red", { size: 13, color: t.mute, anchor: "middle" });
  b += path(t, `M${review},${y + 118} C${review},${y + 232} ${dev - 24},${y + 232} ${dev - 24},${y + 122}`, { dash: true });
  b += text(t, (review + dev) / 2, y + 236, "red CI or review findings: back to develop", { size: 13, color: t.mute, anchor: "middle" });

  b += box(t, 40, 410, W - 80, 210, { fill: t.warnSoft, stroke: t.warn });
  b += text(t, 64, 444, "Hooks that stop the agent, whatever it was told", { size: 18, weight: 700 });
  const guards = [
    ["git reset --hard, push --force, rm -rf ~", "destructive guard"],
    ["push to the main branch of a code repo", "pre-push"],
    ["gh pr create without the /ship receipt", "proposal guard"],
    ["a commit message in the wrong language", "commit-msg"],
    ["closing the session with knowledge only on this machine", "memory and docs gates"],
    ["running a long suite in the foreground", "wait guard"],
  ];
  guards.forEach(([what, who], i) => {
    const col = i % 2, row = Math.floor(i / 2);
    const x = 64 + col * 552, yy = 482 + row * 44;
    b += dot(t, x + 6, yy - 5, t.warn);
    b += text(t, x + 22, yy, what, { size: 14, mono: true });
    b += text(t, x + 22, yy + 19, who, { size: 12, color: t.mute });
  });
  return svg(W, H, t, b);
}

// 3. Switching machines
function machines(t) {
  const W = 1200, H = 470;
  let b = "";
  b += text(t, 40, 52, "Switching machines", { size: 24, weight: 700 });
  b += text(t, 40, 80, "Leave with nothing trapped, arrive with everything: projects, your profile, open tasks and the kernel.", { size: 15, color: t.mute });

  b += box(t, 40, 120, 320, 300);
  b += text(t, 64, 154, "Machine you leave", { size: 18, weight: 700 });
  b += text(t, 64, 190, "crux sync --leave", { size: 15, weight: 700, color: t.accent, mono: true });
  b += lines(t, 64, 222, ["fails if anything would stay here:", "· uncommitted changes", "· unpushed commits and branches", "· commits on a detached HEAD", "· repos whose remote is gone", "· tasks not yet published"], { size: 14, gap: 24, color: t.mute });

  b += box(t, 440, 150, 320, 240, { fill: t.accentSoft, stroke: t.accent });
  b += text(t, 464, 184, "Your git remote", { size: 18, weight: 700 });
  b += lines(t, 464, 220, ["<project>-docs   + crux/tasks", "code repos", "agent-profile", "crux, tagged releases"], { size: 14, gap: 28, mono: true });
  b += text(t, 464, 362, "credentials never travel: carry-env", { size: 13, color: t.mute });

  b += box(t, 840, 120, 320, 300);
  b += text(t, 864, 154, "Machine you arrive at", { size: 18, weight: 700 });
  b += text(t, 864, 190, "crux bootstrap", { size: 15, weight: 700, color: t.accent, mono: true });
  b += lines(t, 864, 216, ["a blank machine: discovers every", "project from the remote"], { size: 14, gap: 22, color: t.mute });
  b += text(t, 864, 280, "crux sync", { size: 15, weight: 700, color: t.accent, mono: true });
  b += lines(t, 864, 306, ["one you used before: advances what", "is behind, brings the tasks and", "the latest kernel; never joins", "diverged branches for you"], { size: 14, gap: 22, color: t.mute });

  b += line(t, 362, 270, 436, 270, { accent: true });
  b += line(t, 762, 270, 836, 270, { accent: true });
  return svg(W, H, t, b);
}

const diagrams = [["memory", memory], ["cycle", cycle], ["machines", machines]];
for (const [name, fn] of diagrams) writeFileSync(join(OUT, `${name}.svg`), fn(THEME));

let chromium;
try {
  ({ chromium } = createRequire(import.meta.url)(process.env.PLAYWRIGHT_PATH || join(homedir(), ".cache/visual-test/node_modules/playwright-core")));
} catch {
  console.log("SVG written; no playwright-core, so no PNG (set PLAYWRIGHT_PATH)");
  process.exit(0);
}
const browser = await chromium.launch({ channel: "chrome" });
const page = await browser.newPage({ deviceScaleFactor: 2 });
for (const [name] of diagrams) {
  await page.goto("file://" + join(OUT, `${name}.svg`));
  await (await page.$("svg")).screenshot({ path: join(OUT, `${name}.png`), omitBackground: true });
}
await browser.close();
console.log("diagrams written to", OUT);
