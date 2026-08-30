---
name: drive-browser
description: Pilotar un navegador CON la sesión ya iniciada del usuario desde la terminal (navegar, clicar, rellenar, capturar) por el protocolo de depuración (CDP), cuando no hay una herramienta MCP de navegador disponible. Usa cuando tengas que operar un panel externo autenticado —Vercel, Stripe, un dashboard, la consola de un proveedor— reusando las cookies del Chrome del usuario; cuando digan "conéctate a mi navegador", "usa mi sesión", "hazlo tú en Vercel/Stripe"; o cuando intentes abrir un puerto de depuración y Chrome lo rechace o salga a la pantalla de login.
---

# drive-browser

Controlar el Chrome del usuario —con sus cookies de sesión— desde la terminal,
por CDP (`--remote-debugging-port`). Es lo que hace falta cuando el trabajo es
"entra en mi Vercel y conéctame la base de datos" y **no hay MCP de navegador**:
no tienes una herramienta nativa de "navega/clica", así que fabricas el puente.

La idea central: **una sesión de Chrome viva y autenticada** más un cliente CDP
que le manda `Page.navigate`, `Runtime.evaluate` y `Page.captureScreenshot`.

## Cuándo usar / Cuándo no usar

**Usar** cuando necesites operar una web **autenticada** con la sesión del
usuario: clicar por un panel, rellenar un formulario, leer un valor tras login.

**No usar** si:
- Solo quieres **capturas de tu propia app** en localhost para pulir responsive
  → usa `visual-test` (Chrome headless nuevo, sin sesión: es otro problema).
- **Hay un MCP de navegador** (`claude mcp list` lo muestra) → úsalo, es mejor
  que esto. Si no lo hay y vas a repetir, instala uno (ver abajo).

## Antes de nada: ¿hay MCP de navegador?

```bash
claude mcp list        # ¿aparece chrome-devtools / playwright / browser?
```

Si no aparece **y quieres que sea fácil de aquí en adelante**, instala uno (se
carga al **reiniciar** Claude Code, no en la sesión actual):

```bash
# Conecta a un Chrome por su endpoint de depuración (reusa sesión):
claude mcp add chrome-devtools -s user -- npx -y chrome-devtools-mcp@latest --browser-url http://127.0.0.1:9222
```

Para **ahora mismo**, sin reiniciar, sigue con CDP a mano (el resto de la skill).

## Precondiciones

- `google-chrome` instalado y **sesión de escritorio activa** (`echo $DISPLAY`
  no vacío). Headed es obligatorio: ver gotcha del llavero.
- `python3` con `websockets` (`python3 -c "import websockets"`).
- El llavero desbloqueado (lo está si el usuario tiene Chrome abierto).

## El procedimiento

1. **Encuentra el perfil que tiene la sesión.** No suele ser `Default`. Mira en
   cuál están las cookies del sitio:
   ```bash
   python3 - <<'PY'
   import sqlite3, glob, os
   ch=os.path.expanduser("~/.config/google-chrome")
   for p in glob.glob(ch+"/*/Cookies"):
       c=sqlite3.connect(p)
       n=c.execute("select count(*) from cookies where host_key like '%vercel%'").fetchone()[0]
       print(p, "->", n); c.close()
   PY
   ```

2. **Lanza Chrome headed con puerto de depuración sobre una COPIA del perfil**,
   desacoplado para que sobreviva entre llamadas (background task del harness):
   ```bash
   <dir-de-esta-skill>/scripts/chrome-session.sh ~/.config/google-chrome/"Profile 1"
   ```
   Espera a CDP: `curl -s http://127.0.0.1:9222/json/version`.

3. **Verifica que la sesión viajó** (no login): navega y lee la URL final.
   ```bash
   python3 <dir-de-esta-skill>/scripts/cdp.py goto https://vercel.com/dashboard /tmp/dash.png 6
   # URL: https://vercel.com/<equipo>...  -> logueado. Si es /login -> falló el descifrado.
   ```

4. **Pilota**: navega, clica y rellena por JS (más fiable que coordenadas), y
   captura para ver el estado.
   ```bash
   python3 .../cdp.py evalshot '[...document.querySelectorAll("button,a")].find(e=>e.textContent.trim()==="Create Database")?.click()??"no"' /tmp/x.png 3
   python3 .../cdp.py eval 'location.href'
   ```

5. **Al terminar, limpia**: cierra por puerto y borra la copia (tiene cookies):
   ```bash
   fuser -k 9222/tcp; rm -rf /tmp/cdp-profile
   ```

## Gotchas (lo que cuesta tiempo)

- **No hay MCP de navegador en Claude Code de terminal por defecto.** Solo
  aparecen los de claude.ai (Gmail/Drive/…). La extensión de Claude para Chrome
  **no** es invocable desde aquí. Confírmalo con `claude mcp list` antes de
  teorizar por qué "no puedes navegar".
- **Chrome RECHAZA depurar el perfil por defecto**: `DevTools remote debugging
  requires a non-default data directory`. Por eso se copia el perfil a un
  `--user-data-dir` aparte. No hay forma de saltárselo.
- **Las cookies van cifradas con el llavero del sistema.** Headless **no** las
  descifra (sale la pantalla de login aunque copies las cookies). Tiene que ser
  **headed** (con `DISPLAY`) y `--password-store=gnome-libsecret`. Y hay que
  copiar **`Local State`** (lleva la clave envuelta) además de `Cookies`.
- **Auto-kill al matar Chrome.** `pkill -f "remote-debugging-port=9222"` coincide
  con **tu propia línea de comando** y se manda SIGTERM a sí mismo (sale 143/144
  sin hacer nada). **Mata por puerto**: `fuser -k 9222/tcp`.
- **El harness mata los procesos en segundo plano** al terminar la llamada. Por
  eso Chrome se lanza como *background task* persistente y se pilota con llamadas
  CDP cortas y separadas; la copia del perfil conserva las cookies entre ellas.
- **No puedes adjuntarte al Chrome real del usuario**: un perfil no admite dos
  instancias, y encima es el perfil por defecto (prohibido depurar). Copia el
  perfil; dos Chrome coexisten en `--user-data-dir` distintos.
- **`urllib` a 127.0.0.1 puede irse por un proxy** del entorno → usa
  `build_opener(ProxyHandler({}))` (ya está en `cdp.py`).
- **UIs de React**: muchos "botones" son `div`. Clica por texto con
  `querySelector(...).click()` (burbujea a React). Para inputs controlados, pon
  el valor con el setter nativo y dispara `input`/`change`. El contenedor con
  scroll es el `div` cuyo `scrollHeight>clientHeight`.

## Secretos: nunca los imprimas

Para sacar una cadena de conexión o token de la web sin que pase por el
contexto: que el JS lo deje en `window.__X__`, y vuélcalo a fichero con la
acción `writefile` (lee el valor y lo escribe a disco con `chmod 600`, imprime
solo la longitud). Luego consúmelo desde el fichero.

```bash
python3 .../cdp.py eval 'window.__X__=document.body.innerText.match(/DATABASE_URL=(\S+)/)[1]; "len="+window.__X__.length'
python3 .../cdp.py writefile 'window.__X__' /tmp/secret   # no imprime el valor
```

## Cómo verificar que funcionó

La URL final tras `goto` a una página protegida: si redirige a login, el
descifrado de cookies falló (casi siempre por lanzar headless). Si carga el
panel, la sesión viajó y puedes pilotar.

## Relacionado

- `visual-test` — capturas headless de TU app (sin sesión). Otro problema.
- `share-local` — abrir tu local al exterior con un túnel.
- `oauth-reauthorize` — cuando lo que falla es un token OAuth, no la sesión web.
