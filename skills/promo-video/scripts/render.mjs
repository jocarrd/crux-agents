#!/usr/bin/env node
/* Renderiza un escenario a fotogramas sueltos.
 *
 * El escenario expone window.__duration y window.__seek(t). Se le pide cada
 * instante y se captura: asi el resultado no depende de lo rapido que vaya la
 * maquina, que es lo que diferencia esto de grabar la pantalla.
 *
 *   node render.mjs escenario.html salida/ [fps] [ancho] [alto]
 */
import { mkdirSync, rmSync, existsSync } from "node:fs";
import { createRequire } from "node:module";
import { homedir } from "node:os";
import { resolve, join } from "node:path";

/* La skill vive fuera de cualquier proyecto, asi que playwright-core no se
   resuelve por el camino normal. Se busca donde suele estar antes de rendirse. */
function cargarPlaywright() {
  const req = createRequire(import.meta.url);
  const candidatos = [
    process.env.PLAYWRIGHT_PATH,
    join(process.cwd(), "node_modules/playwright-core"),
    join(homedir(), ".cache/visual-test/node_modules/playwright-core"),
    join(homedir(), ".cache/mobile-audit/node_modules/playwright-core"),
    "playwright-core",
  ].filter(Boolean);
  for (const c of candidatos) {
    try { return req(c); } catch { /* siguiente */ }
  }
  console.error(
    "No encuentro playwright-core. Instalalo con `npm i playwright-core` en el\n" +
    "directorio desde el que lanzas esto, o exporta PLAYWRIGHT_PATH.",
  );
  process.exit(1);
}
const { chromium } = cargarPlaywright();

const [html, destino, fps = "30", ancho = "1920", alto = "1080"] = process.argv.slice(2);
if (!html || !destino) {
  console.error("uso: render.mjs <escenario.html> <carpeta-salida> [fps] [ancho] [alto]");
  process.exit(1);
}
if (!existsSync(html)) { console.error("no existe:", html); process.exit(1); }

const FPS = Number(fps);
rmSync(destino, { recursive: true, force: true });
mkdirSync(destino, { recursive: true });

const browser = await chromium.launch({ channel: "chrome", args: ["--force-device-scale-factor=1"] });
const page = await browser.newPage({
  viewport: { width: Number(ancho), height: Number(alto) },
  deviceScaleFactor: 1,
});

await page.goto("file://" + resolve(html), { waitUntil: "load" });
await page.waitForTimeout(1200);

// Una imagen a medio cargar en un fotograma no se recupera despues.
await page.evaluate(() =>
  Promise.all([...document.images].map((i) => (i.complete ? 1 : i.decode().catch(() => 1)))),
);
await page.waitForTimeout(400);

const duracion = await page.evaluate(() => window.__duration);
if (!duracion) {
  console.error("el escenario no expone window.__duration");
  await browser.close();
  process.exit(1);
}

const total = Math.round(duracion * FPS);
console.log(`${duracion}s a ${FPS} fps -> ${total} fotogramas`);

for (let f = 0; f < total; f++) {
  await page.evaluate((t) => window.__seek(t), f / FPS);
  await page.screenshot({ path: `${destino}/f${String(f).padStart(5, "0")}.png` });
  if (f % 60 === 0) process.stdout.write(`  ${f}/${total}\r`);
}

console.log(`\nlisto: ${total} fotogramas en ${destino}`);
await browser.close();
