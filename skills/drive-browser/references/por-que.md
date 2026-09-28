# Por qué se pilota así

El procedimiento está en `SKILL.md`.

## Por qué hace falta

El trabajo tipo es "entra en mi Vercel y conéctame la base de datos". Sin una
herramienta de navegador no hay forma nativa de navegar o clicar, así que se
fabrica el puente: una sesión de Chrome viva y autenticada, y un cliente CDP que
le manda `Page.navigate`, `Runtime.evaluate` y `Page.captureScreenshot`. El
agente de terminal no suele traer MCP de navegador por defecto (solo los de
claude.ai: Gmail, Drive…), y la extensión para Chrome no se puede invocar desde
aquí.

## Por qué una copia del perfil

Chrome rechaza depurar el perfil por defecto: `DevTools remote debugging
requires a non-default data directory`. Un perfil tampoco admite dos
instancias, así que no te puedes adjuntar al Chrome real del usuario. Dos Chrome
conviven sin problema en `--user-data-dir` distintos.

## Por qué headed

Las cookies van cifradas con el llavero del sistema. Headless no las descifra y
sale la pantalla de login aunque las hayas copiado. `Local State` lleva la clave
envuelta, por eso se copia junto a `Cookies`.

## Google

Las cookies viajan y se descifran (se ven `SID`, `HSID`, `__Secure-1PSID`), pero
Google las ata al dispositivo de origen y el selector de cuentas sale con
"Sesión cerrada". Malt y Vercel sí las aceptan.

## El clic

React ignora los eventos no confiables en algunos componentes: ni
`element.click()` ni un `MouseEvent` sintético con `dispatchEvent` los disparan.
`Input.dispatchMouseEvent`, que es lo que usa la acción `click` de `cdp.py`, fue
la diferencia entre avanzar y no avanzar en un alta completa. El `.click()` de
JS funciona en otros sitios porque el evento burbujea hasta React, por eso queda
como segunda opción.

## pkill

`pkill -f "remote-debugging-port=9222"` coincide con tu propia línea de comando
y se manda SIGTERM a sí mismo (sale con 143 o 144 sin hacer nada). Además el
guardia de comandos destructivos lo bloquea.

## Pestañas colgadas

Una pestaña puede dejar colgado `Runtime.evaluate` mientras CDP sigue
respondiendo por HTTP. Matar Chrome haría perder la sesión.

## Procesos en segundo plano

El entorno del agente mata los procesos en segundo plano al terminar cada
llamada. Por eso Chrome se lanza como tarea persistente y se pilota con
llamadas cortas; la copia del perfil conserva las cookies entre ellas.
