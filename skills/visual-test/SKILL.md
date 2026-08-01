---
name: visual-test
description: Inspeccionar visualmente páginas y componentes web en viewport móvil (390px) y escritorio (1280px) con Chrome headless. Hace capturas, detecta scroll horizontal y localiza el elemento exacto que desborda, reporta señales objetivas de usabilidad móvil y ejecuta una auditoría de accesibilidad real con axe-core. Usa cuando pulas diseño responsive, te reporten que algo se ve mal en móvil, caces un desbordamiento horizontal, o quieras comparar móvil y escritorio antes de desplegar.
---

# Visual test

Inspección visual headless con el Chrome del sistema. No es testing de
aserciones: es para **ver** la página como en un móvil real, **detectar scroll
horizontal** y **cazar el elemento culpable** sin teorizar.

## Cuándo usar

- Te reportan que en móvil se ve mal o aparece scroll horizontal.
- Vas a pulir responsive y quieres iterar viendo el resultado.
- Quieres confirmar que un arreglo de layout se ve bien en los dos viewports.

## Precondiciones

- `google-chrome` o `chromium` instalado. Se autodetecta; se puede forzar con
  `CHROME_BIN`.
- La aplicación corriendo en local, y su puerto a mano.

## Preparación, una vez

`playwright-core` lanza el Chrome del sistema en vez de descargar un navegador.
Se instala en un directorio de caché junto al script, porque ESM resuelve el
import relativo al fichero:

```bash
mkdir -p ~/.cache/visual-test && cd ~/.cache/visual-test
[ -d node_modules/playwright-core ] || npm i playwright-core >/dev/null 2>&1
cp "<directorio-de-esta-skill>/scripts/visual.mjs" .
```

## Uso

```bash
cd ~/.cache/visual-test

# Captura móvil, opcionalmente con scroll a un offset
node visual.mjs shot http://localhost:3000/ruta /tmp/a.png --scroll 560
# Captura escritorio
node visual.mjs shot http://localhost:3000/ruta /tmp/a-d.png --desktop

# Auditar scroll horizontal en una o varias páginas
node visual.mjs audit http://localhost:3000/ http://localhost:3000/otra

# Localizar el elemento que desborda: oculta cada nodo y mide
node visual.mjs bisect http://localhost:3000/ruta

# Señales objetivas de usabilidad móvil
node visual.mjs checks http://localhost:3000/ruta

# Auditoría WCAG real con axe-core
node visual.mjs a11y http://localhost:3000/ruta
node visual.mjs a11y http://localhost:3000/ruta --desktop
```

Después, abre las capturas para mirarlas. Ese paso no es opcional: el objetivo
de la skill es ver, no deducir.

## Los dos niveles de análisis

**A ojo.** `shot` genera la captura; ábrela y juzga jerarquía, espaciado,
alineación y legibilidad. El criterio es insustituible aquí.

**Señales objetivas.** `checks` reporta lo medible: áreas táctiles por debajo
de 44px, texto por debajo de 12px, imágenes sin alt y texto pegado a los
bordes. Da pistas, no veredictos: algunos resultados son intencionados —texto
solo para lectores de pantalla, leyendas pequeñas— y hay que filtrarlos.

`a11y` inyecta axe-core y agrupa las violaciones por impacto con su selector y
su motivo. Necesita red. Es mucho más fiable que las heurísticas de `checks`
para accesibilidad real.

## Cómo leer la auditoría

- `innerWidth=390 overflowH=0px ok` — sin scroll horizontal.
- `innerWidth=509 ... scroll horizontal` — algo fuerza un ancho mínimo de
  509px y el navegador hace zoom-out. Lanza `bisect` para encontrarlo.
- `bisect` ordena los nodos cuyo ocultado recorta más ancho. **El culpable real
  es el que tiene `kids=0`** (una hoja); los ancestros aparecen porque
  ocultarlos también lo elimina.

## Causas típicas de scroll horizontal

- **Un flex-item sin `min-width: 0`** que contiene texto truncado o sin
  saltos: el `min-width: auto` por defecto impide encoger, y el ancho mínimo
  del contenido manda. Se arregla en el contenedor, no en el texto.
- **Un elemento a sangre completa con márgenes negativos** colocado fuera del
  contenedor que aporta el padding: el margen negativo se sale. Se arregla
  envolviéndolo en un elemento con el padding correspondiente.
- **`overflow-x: hidden` en la raíz** enmascara el problema en esa página pero
  no lo arregla, y reaparece en cualquier otra. Busca la causa con `bisect`.

## Gotchas

- **Algunos bundlers en modo desarrollo no recompilan de forma fiable los
  cambios del layout raíz.** Tras tocarlo, reinicia el servidor de desarrollo
  antes de volver a auditar, o medirás el estado anterior.
- **Los errores de carga de chunks dinámicos** en el primer render headless
  pueden disparar el error boundary. El script calienta dos veces para
  evitarlo; si aun así ves la página de error, reintenta.
- **Los elementos decorativos en `position: absolute`** que sobresalen dentro
  de un contenedor con `overflow: hidden` son falsos positivos. El script ya
  ignora `absolute` y `fixed`.
- **Para matar el servidor de desarrollo, mata por PID.** Un `pkill` por
  patrón puede llevarse por delante tu propia shell.

## Relacionado

- `/device-loop` — la hermana nativa: ver la app real en un dispositivo físico
- `/render-loop` — iterar sobre una salida renderizada sin referencia
