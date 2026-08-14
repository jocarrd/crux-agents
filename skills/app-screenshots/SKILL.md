---
name: app-screenshots
description: Generar el juego de capturas del recorrido de una aplicación web, pantalla a pantalla y con sesión iniciada, dejando escrito el recorrido para que la siguiente tanda no empiece de cero. Usa cuando las capturas de la documentación se hayan quedado viejas, cuando te pidan "actualiza las capturas", "hazme un recorrido de la app" o pantallas para una presentación, un traspaso o un manual, y cuando un rediseño haya dejado obsoleto todo lo que había.
---

# App screenshots

Un juego de capturas envejece en silencio: nadie las mira hasta que hacen falta,
y para entonces enseñan una aplicación que ya no existe. Esta skill las
regenera de una pasada y deja **el recorrido escrito**, que es lo que evita
tener que reconstruirlo la próxima vez.

La idea central: **el motor es genérico y el recorrido es del proyecto**. El
script no sabe nada de tu aplicación; lee un guion que dice qué pantalla, con
qué sesión y con qué dato.

## Cuándo usar

- Las capturas de la documentación son de antes del último rediseño.
- Alguien pide pantallas para una presentación, un traspaso o un manual.
- Acabas una tanda que cambia el aspecto y quieres dejar constancia de cómo
  quedó.

## Cuándo no usar

- **Una sola página**, o quieres auditar responsive y accesibilidad: eso es
  `visual-test`, que además caza desbordamientos.
- **Iterar un diseño** viendo el efecto de cada cambio: `render-loop`.
- **Comparar contra una referencia** para medir desviación: `visual-diff`.
- **Enseñar el producto en movimiento**: eso es un vídeo, no un juego de
  capturas.

## Preparación, una vez

`playwright-core` lanza el Chrome del sistema en vez de descargar un navegador.
Se instala en un directorio de caché junto al script, porque **ESM resuelve el
import relativo al fichero**, no al directorio desde el que ejecutas:

```bash
mkdir -p ~/.cache/app-screenshots && cd ~/.cache/app-screenshots
[ -d node_modules/playwright-core ] || npm i playwright-core >/dev/null 2>&1
cp "<directorio-de-esta-skill>/scripts/tour.mjs" .
```

El guion se pasa por **ruta absoluta**, y su `out` se resuelve relativo a él: da
igual desde dónde ejecutes.

## El procedimiento

### 1. Inventaría las pantallas que existen de verdad

Antes de capturar nada, saca la lista de rutas **del código**, no de la
documentación antigua:

```bash
find app -name "page.tsx" | sed 's|/page.tsx||'     # Next.js app router
grep -rn "createBrowserRouter\|<Route" src/         # React Router
```

Contrástala con el índice que ya exista. Lo que sobra en el índice y no está en
el código es la primera lista de borrado.

**Una captura por superficie, no por ruta.** Dos rutas que renderizan lo mismo
son una sola pantalla; lo confirmarás en el paso 4.

### 2. Elige el dato que enseña la pantalla que quieres

Es el paso que más veces se hace mal. Una pantalla de configuración enseña la
configuración **solo si el registro está en el estado adecuado**; si no, enseña
un mensaje de "no hay nada que configurar" y la captura no sirve para nada.

Antes de fijar los identificadores en el guion, consúltalos en la base de datos
y comprueba en qué estado están:

```sql
select id, status from <tabla> order by status;
```

**Esos identificadores caducan.** Si el proyecto siembra datos de demostración,
cambian en cada siembra: el guion se rehace, no se hereda.

### 3. Escribe el guion

```json
{
  "base": "http://localhost:3000",
  "out": "../capturas",
  "viewport": { "width": 1440, "height": 900, "scale": 2 },
  "hide": ["nextjs-portal"],
  "login": { "route": "/login" },
  "sessions": {
    "admin": { "emailEnv": "TOUR_ADMIN_EMAIL", "passwordEnv": "TOUR_ADMIN_PASS" },
    "cliente": { "email": "demo@example.test", "passwordEnv": "TOUR_DEMO_PASS" }
  },
  "scenes": [
    { "name": "01-acceso", "route": "/login" },
    { "name": "10-panel", "as": "admin", "route": "/admin" },
    { "name": "11-detalle", "as": "admin", "route": "/admin/x/123" },
    { "name": "20-paso-2", "as": "cliente", "route": "/flujo/1", "click": "Siguiente" }
  ]
}
```

- `out` es relativo al guion.
- Las **contraseñas nunca van en el guion**: se declaran por variable de entorno
  y el script falla si no están.
- Una escena sin `as` se captura sin sesión, borrando las cookies antes.
- `click` sirve para las pantallas a las que no se llega por URL: pulsa el
  elemento cuyo texto coincide exactamente.
- Numera con huecos (01, 10, 11, 20): así insertar una pantalla no obliga a
  renumerar el resto.

### 4. Captura y lee lo que informa

```bash
cd ~/.cache/app-screenshots
node tour.mjs /ruta/al/recorrido.json           # todas
node tour.mjs /ruta/al/recorrido.json cliente   # solo las que contengan "cliente"
node tour.mjs /ruta/al/recorrido.json --check   # solo el informe de duplicados
```

Dos avisos importan:

- **`CAYO EN EL ACCESO`**: la escena terminó en la pantalla de login. La sesión
  no tenía permiso o la ruta exige otro rol. Esa captura no vale.
- **`IDENTICAS`**: dos escenas dieron el mismo píxel. Casi siempre es una ruta
  que redirige a otra. Confírmalo en el código antes de borrar una: si es un
  `redirect`, no es una pantalla, es un alias.

### 5. Míralas

**Que el fichero exista no significa que la captura sirva.** Ábrelas. Es donde
se ve que una pantalla salió en el estado equivocado, que un panel está vacío
porque faltaba el dato, o que hay un defecto real de la aplicación que nadie
había visto —las capturas de pantallas que nadie visita son un buen detector de
maquetación rota—.

### 6. Escribe el índice

Junto a las capturas, un documento que diga:

- **Cuándo se generaron.** Sin fecha no se sabe si mienten.
- **Qué muestra cada una**, con el dato concreto: qué escenario, qué caso.
- **El recorrido**: sesión y ruta de cada captura, para que la próxima tanda no
  vuelva a investigarlo.
- **Qué se retiró y por qué.** Un borrado sin motivo escrito se deshace solo.
- **Las cifras que no sean de fiar.** Si los datos de demostración no producen
  los valores que dicen producir, escríbelo ahí: alguien va a meter esa captura
  en una presentación.

## Gotchas

**La caché del servidor de desarrollo produce capturas que mienten.** Es el que
más tiempo cuesta, porque no falla: sirve el HTML anterior con los estilos
nuevos, y salen elementos sin estilo o con el anterior. Se reconoce porque el
DOM tiene clases que ya no están en el código. Antes de una tanda que vaya a
comparar contra algo, **borra la caché de compilación, reinicia y haz una pasada
de calentamiento** visitando las rutas; la primera visita compila, la segunda
retrata.

**El indicador de desarrollo del framework sale en todas.** Va en `hide`. En
Next.js es `nextjs-portal`.

**Las fuentes web cambian la maquetación al cargar.** El script espera a
`document.fonts.ready`; si aun así ves saltos, sube `settle` en esa escena.

**Los relojes y cronómetros hacen imposible repetir una captura.** Dos pasadas
de la misma pantalla difieren en unos píxeles, así que el detector de duplicados
no las verá: eso hay que cazarlo mirando.

**Hay pantallas que no son deterministas.** Una lista que pagina según el alto
disponible da un número de filas distinto según el viewport; un registro de
actividad crece con el uso, y capturar genera actividad. Anótalo en el índice en
vez de perseguirlo.

**Cambiar de sesión exige borrar las cookies**, no basta con navegar al acceso:
el script lo hace, pero si automatizas por tu cuenta, es el fallo típico.

## Anti-patterns

- **Capturar sin mirar.** El fichero existe y está mal.
- **Heredar los identificadores del guion anterior.** Caducan con los datos.
- **Una captura por ruta.** Los alias y los redirects inflan el juego sin
  añadir información.
- **Borrar capturas sin escribir el motivo.** La siguiente tanda las repone.
- **Dejar el guion con contraseñas dentro.** Van por variable de entorno.

## Relacionado

- `visual-test` — auditar una página: responsive, desbordamiento, accesibilidad
- `visual-diff` — medir la desviación contra una referencia
- `render-loop` — iterar un diseño viendo el resultado
