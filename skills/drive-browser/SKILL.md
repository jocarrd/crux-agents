---
name: drive-browser
description: Pilotar un navegador CON la sesión ya iniciada del usuario desde la terminal (navegar, clicar, rellenar, capturar) por el protocolo de depuración (CDP), cuando no hay una herramienta MCP de navegador disponible. Usa cuando tengas que operar un panel externo autenticado —Vercel, Stripe, un dashboard, la consola de un proveedor— reusando las cookies del Chrome del usuario; cuando digan "conéctate a mi navegador", "usa mi sesión", "hazlo tú en Vercel/Stripe"; o cuando intentes abrir un puerto de depuración y Chrome lo rechace o salga a la pantalla de login.
---

# drive-browser

Controlar el Chrome del usuario, con sus cookies de sesión, desde la terminal
por CDP (`--remote-debugging-port`), cuando hay que operar una web autenticada
y no hay herramienta de navegador. Por qué cada restricción:
`<directorio-de-esta-skill>/references/por-que.md`.

**No usar** para capturas de tu propia app en local (`/visual-test`), ni si hay
un MCP de navegador disponible: compruébalo con `claude mcp list`. Si vas a
repetir, instala uno (carga al reiniciar el agente):
`claude mcp add chrome-devtools -s user -- npx -y chrome-devtools-mcp@latest --browser-url http://127.0.0.1:9222`.

## Hace falta

- `google-chrome` y **sesión de escritorio** (`echo $DISPLAY` no vacío): tiene
  que ser headed.
- `python3` con `websockets`.
- El llavero desbloqueado (lo está si el usuario tiene Chrome abierto).

## Procedimiento

1. **El perfil con la sesión** (no suele ser `Default`):

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

2. **Lanza Chrome headed sobre una copia del perfil**, como tarea en segundo
   plano persistente:
   `<directorio-de-esta-skill>/scripts/chrome-session.sh ~/.config/google-chrome/"Profile 1"`.
   Espera a `curl -s http://127.0.0.1:9222/json/version`.

3. **Comprueba que la sesión viajó:**
   `python3 <directorio-de-esta-skill>/scripts/cdp.py goto https://vercel.com/dashboard /tmp/dash.png 6`.
   Si acaba en la página de login, el descifrado falló (casi siempre por lanzar headless).

4. **Pilota** con llamadas cortas y separadas:
   - Clic: **la acción `click` de `cdp.py`**, que manda eventos de ratón reales.
     El `.click()` de JS o un `MouseEvent` sintético no disparan nada en muchas
     SPA; úsalos solo si `click` no encuentra el elemento.
   - Leer y ejecutar: `cdp.py eval '<js>'` y `cdp.py evalshot '<js>' <png> <s>`.
   - Inputs controlados: el setter nativo y `input`/`change`. Con
     autocompletado, el valor a "" con el setter y luego `type`; si no sale el
     desplegable, Enter.
   - En React muchos botones son `div`: búscalos por texto.

5. **Al terminar**, cierra por puerto y borra la copia, que tiene cookies:

   ```bash
   fuser -k 9222/tcp; rm -rf /tmp/cdp-profile
   ```

## Secretos: nunca los imprimas

Deja el valor en `window.__X__` y vuélcalo a fichero con `writefile`, que
escribe con `chmod 600` e imprime solo la longitud:

```bash
python3 .../cdp.py eval 'window.__X__=document.body.innerText.match(/DATABASE_URL=(\S+)/)[1]; "len="+window.__X__.length'
python3 .../cdp.py writefile 'window.__X__' /tmp/secret
```

## Gotchas

- **Google no acepta el perfil copiado:** pide al usuario que inicie sesión una
  vez en la ventana headed y sigue tú. Otras webs sí aceptan las cookies.
- **Chrome no depura el perfil por defecto** ni puedes adjuntarte al Chrome
  real del usuario: siempre una copia en otro `--user-data-dir`.
- **Headless no descifra las cookies:** headed, con
  `--password-store=gnome-libsecret` y copiando también `Local State` (el
  script ya lo hace).
- **Si `eval` se queda colgado,** no mates Chrome: abre pestaña nueva
  (`curl -s -X PUT "http://127.0.0.1:9222/json/new?<url>"`) y cierra la vieja
  (`/json/close/<targetId>`).
- **Mata por puerto (`fuser -k 9222/tcp`), nunca con `pkill`.**
- **El entorno mata los procesos en segundo plano** al terminar cada llamada:
  Chrome va como tarea persistente.
- `urllib` a `127.0.0.1` puede salir por un proxy; `cdp.py` ya lo evita.
- El contenedor con scroll es el `div` con `scrollHeight > clientHeight`.

## Relacionado

- `/visual-test` — capturas headless de tu app, sin sesión
- `/share-local` — abrir tu local al exterior
- `/oauth-reauthorize` — cuando falla un token OAuth, no la sesión web
