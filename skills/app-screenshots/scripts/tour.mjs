#!/usr/bin/env node
// Recorre una aplicación web autenticada y deja un juego de capturas.
// Uso:
//   node tour.mjs <guion.json> [filtro]   captura las escenas (filtro = subcadena del nombre)
//   node tour.mjs <guion.json> --check    solo informa: escenas duplicadas y sesiones caidas
//
// Requiere google-chrome o chromium instalado y playwright-core junto a este fichero.
import { existsSync, mkdirSync, readFileSync, readdirSync } from "node:fs";
import { createHash } from "node:crypto";
import { dirname, join, resolve } from "node:path";
import { chromium } from "playwright-core";

const CHROME =
  process.env.CHROME_BIN ||
  ["/usr/bin/google-chrome", "/usr/bin/chromium", "/usr/bin/chromium-browser"].find((p) =>
    existsSync(p),
  ) ||
  "/usr/bin/google-chrome";

const [guionPath, arg] = process.argv.slice(2);
if (!guionPath) {
  console.error("uso: node tour.mjs <guion.json> [filtro|--check]");
  process.exit(2);
}

const guion = JSON.parse(readFileSync(guionPath, "utf8"));
const soloInforme = arg === "--check";
const filtro = soloInforme ? null : arg;

const BASE = (process.env.TOUR_BASE || guion.base || "http://localhost:3000").replace(/\/$/, "");
const OUT = resolve(dirname(resolve(guionPath)), guion.out || "capturas");
const VP = { width: 1440, height: 900, scale: 2, ...(guion.viewport || {}) };
const LOGIN = {
  route: "/login",
  email: 'input[type="email"], input[name="email"]',
  password: 'input[type="password"], input[name="password"]',
  submit: 'button[type="submit"]',
  ...(guion.login || {}),
};

/** Las credenciales nunca viven en el guion: se declaran por variable de entorno. */
function credenciales(nombre) {
  const s = (guion.sessions || {})[nombre];
  if (!s) throw new Error(`sesion "${nombre}" no declarada en el guion`);
  const email = s.email ?? process.env[s.emailEnv];
  const password = s.password ?? process.env[s.passwordEnv];
  if (!email || !password) {
    throw new Error(
      `faltan credenciales de "${nombre}": exporta ${s.emailEnv || "su email"} y ${s.passwordEnv || "su password"}`,
    );
  }
  return { email, password };
}

function huellas(dir) {
  const porHash = new Map();
  for (const f of readdirSync(dir).filter((f) => f.endsWith(".png"))) {
    const h = createHash("sha256").update(readFileSync(join(dir, f))).digest("hex");
    porHash.set(h, [...(porHash.get(h) || []), f]);
  }
  return [...porHash.values()].filter((g) => g.length > 1);
}

if (soloInforme) {
  const dup = existsSync(OUT) ? huellas(OUT) : [];
  if (!dup.length) console.log("sin capturas duplicadas");
  else for (const g of dup) console.log(`IDENTICAS: ${g.join(" == ")}`);
  process.exit(0);
}

mkdirSync(OUT, { recursive: true });

const browser = await chromium.launch({ executablePath: CHROME, args: ["--no-sandbox"] });
const context = await browser.newContext({
  viewport: { width: VP.width, height: VP.height },
  deviceScaleFactor: VP.scale,
});
const page = await context.newPage();

let sesion = null;

async function entrar(nombre) {
  const { email, password } = credenciales(nombre);
  await context.clearCookies();
  await page.goto(`${BASE}${LOGIN.route}`, { waitUntil: "networkidle" });
  await page.fill(LOGIN.email, email);
  await page.fill(LOGIN.password, password);
  await page.click(LOGIN.submit);
  // Esperar a "networkidle" no vale: ya se cumplia antes de que el clic navegue.
  await page
    .waitForURL((u) => !new URL(u).pathname.startsWith(LOGIN.route), { timeout: 30000 })
    .catch(() => {});
  await page.waitForLoadState("networkidle").catch(() => {});
  if (page.url().includes(LOGIN.route)) {
    throw new Error(`el acceso como "${nombre}" no progreso: sigue en ${LOGIN.route}`);
  }
  sesion = nombre;
}

let fallos = 0;

for (const escena of guion.scenes) {
  if (filtro && !escena.name.includes(filtro)) continue;
  try {
    if (!escena.as) {
      await context.clearCookies();
      sesion = null;
    } else if (sesion !== escena.as) {
      await entrar(escena.as);
    }

    await page.goto(`${BASE}${escena.route}`, { waitUntil: "networkidle", timeout: 60000 });

    if (escena.click) {
      const boton = page.getByText(escena.click, { exact: true }).first();
      if (await boton.count()) {
        await boton.click();
        await page.waitForLoadState("networkidle").catch(() => {});
        await page.waitForTimeout(800);
      } else {
        console.log(`  aviso ${escena.name}: no se encontro "${escena.click}"`);
      }
    }

    // El cromo del modo desarrollo no forma parte del producto.
    const ocultar = [...(guion.hide || []), ...(escena.hide || [])];
    await page.evaluate(async (sel) => {
      if (sel.length) {
        const s = document.createElement("style");
        s.textContent = `${sel.join(",")}{display:none!important}`;
        document.head.appendChild(s);
      }
      // Sin esperar a las fuentes, las metricas del texto cambian entre tandas.
      await document.fonts.ready;
      for (const a of document.getAnimations()) {
        try {
          a.cancel();
        } catch {}
      }
    }, ocultar);
    await page.waitForTimeout(escena.settle ?? 400);

    const enLogin = escena.as && page.url().includes(LOGIN.route);
    await page.screenshot({ path: join(OUT, `${escena.name}.png`), fullPage: escena.fullPage !== false });
    console.log(`  ${escena.name.padEnd(26)} ${escena.route}${enLogin ? "   <-- CAYO EN EL ACCESO" : ""}`);
    if (enLogin) fallos++;
  } catch (e) {
    console.log(`  ERROR ${escena.name.padEnd(22)} ${e.message.slice(0, 80)}`);
    fallos++;
  }
}

await browser.close();

for (const g of huellas(OUT)) {
  console.log(`\nIDENTICAS: ${g.join(" == ")}`);
  console.log("  dos escenas dan el mismo pixel: suele ser una ruta que redirige a la otra");
}

process.exit(fallos ? 1 : 0);
