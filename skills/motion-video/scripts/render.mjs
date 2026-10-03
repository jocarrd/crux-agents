#!/usr/bin/env node
/* Renders a scene to individual frames.
 *
 * The scene exposes window.__duration and window.__seek(t). Each instant is
 * requested and captured: that way the result does not depend on how fast the
 * machine is, which is what sets this apart from recording the screen.
 *
 *   node render.mjs scene.html output/ [fps] [width] [height]
 */
import { mkdirSync, rmSync, existsSync } from "node:fs";
import { createRequire } from "node:module";
import { homedir } from "node:os";
import { resolve, join } from "node:path";

/* The skill lives outside any project, so playwright-core does not resolve
   the normal way. It is looked up where it usually is before giving up. */
function loadPlaywright() {
  const req = createRequire(import.meta.url);
  const candidates = [
    process.env.PLAYWRIGHT_PATH,
    join(process.cwd(), "node_modules/playwright-core"),
    join(homedir(), ".cache/visual-test/node_modules/playwright-core"),
    join(homedir(), ".cache/mobile-audit/node_modules/playwright-core"),
    "playwright-core",
  ].filter(Boolean);
  for (const c of candidates) {
    try { return req(c); } catch { /* next */ }
  }
  console.error(
    "Cannot find playwright-core. Install it with `npm i playwright-core` in the\n" +
    "directory you run this from, or export PLAYWRIGHT_PATH.",
  );
  process.exit(1);
}
const { chromium } = loadPlaywright();

const [html, target, fps = "30", width = "1920", height = "1080"] = process.argv.slice(2);
if (!html || !target) {
  console.error("usage: render.mjs <scene.html> <output-folder> [fps] [width] [height]");
  process.exit(1);
}
if (!existsSync(html)) { console.error("does not exist:", html); process.exit(1); }

const FPS = Number(fps);
rmSync(target, { recursive: true, force: true });
mkdirSync(target, { recursive: true });

const browser = await chromium.launch({ channel: "chrome", args: ["--force-device-scale-factor=1"] });
const page = await browser.newPage({
  viewport: { width: Number(width), height: Number(height) },
  deviceScaleFactor: 1,
});

await page.goto("file://" + resolve(html), { waitUntil: "load" });
await page.waitForTimeout(1200);

// A half-loaded image in a frame cannot be recovered afterwards.
await page.evaluate(() =>
  Promise.all([...document.images].map((i) => (i.complete ? 1 : i.decode().catch(() => 1)))),
);
await page.waitForTimeout(400);

const duration = await page.evaluate(() => window.__duration);
if (!duration) {
  console.error("the scene does not expose window.__duration");
  await browser.close();
  process.exit(1);
}

const total = Math.round(duration * FPS);
console.log(`${duration}s at ${FPS} fps -> ${total} frames`);

for (let f = 0; f < total; f++) {
  await page.evaluate((t) => window.__seek(t), f / FPS);
  await page.screenshot({ path: `${target}/f${String(f).padStart(5, "0")}.png` });
  if (f % 60 === 0) process.stdout.write(`  ${f}/${total}\r`);
}

console.log(`\ndone: ${total} frames in ${target}`);
await browser.close();
