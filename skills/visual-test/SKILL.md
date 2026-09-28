---
name: visual-test
description: Inspeccionar visualmente páginas y componentes web en viewport móvil (390px) y escritorio (1280px) con Chrome headless. Hace capturas, detecta scroll horizontal y localiza el elemento exacto que desborda, reporta señales objetivas de usabilidad móvil, ejecuta una auditoría de accesibilidad real con axe-core, y caza cuatro cosas que ninguna de las anteriores ve: contenido que una animación de entrada deja invisible para siempre, fallos de hidratación, contraste que solo falla en hover o en estado activo, y el ritmo vertical entre secciones. Usa cuando pulas diseño responsive, te reporten que algo se ve mal en móvil, caces un desbordamiento horizontal, revises animaciones de entrada, o quieras comparar móvil y escritorio antes de desplegar.
---

# Visual test

Inspección visual headless con el Chrome del sistema: ver la página como en un
móvil real, detectar scroll horizontal y cazar el elemento culpable. Los casos
reales detrás de cada comprobación y los gotchas completos están en
`<directorio-de-esta-skill>/references/por-que.md`.

## Preparación, una vez

Hace falta `google-chrome` o `chromium` (se autodetecta; se fuerza con
`CHROME_BIN`) y la aplicación corriendo en local.

```bash
mkdir -p ~/.cache/visual-test && cd ~/.cache/visual-test
[ -d node_modules/playwright-core ] || npm i playwright-core >/dev/null 2>&1
cp "<directorio-de-esta-skill>/scripts/visual.mjs" .
```

## Uso

```bash
cd ~/.cache/visual-test
node visual.mjs shot http://localhost:3000/ruta /tmp/a.png [--scroll 560] [--desktop]
node visual.mjs audit <url> [<url>…]       # scroll horizontal
node visual.mjs bisect <url>               # qué elemento desborda
node visual.mjs checks <url>               # señales de usabilidad móvil
node visual.mjs a11y <url> [--desktop]     # WCAG con axe-core (necesita red)
node visual.mjs invisible <url> [<url>…]   # contenido que se queda en opacity 0
node visual.mjs hydration <url> [<url>…]   # fallos de hidratación
node visual.mjs states <url>               # contraste en reposo y en hover
node visual.mjs rhythm <url>               # aire entre secciones
```

**Abre las capturas y míralas.** No es opcional: la skill es para ver, no para
deducir. Ninguna página se da por buena sin haber mirado su captura en móvil y
en escritorio, pasen lo que pasen los comandos.

## Cómo leer los resultados

- `checks` da pistas, no veredictos (áreas táctiles < 44px, texto < 12px,
  imágenes sin alt, texto pegado al borde); algunas son intencionadas. `a11y` es
  la fuente fiable de accesibilidad.
- `audit`: `innerWidth=390 overflowH=0px ok` está bien; un `innerWidth` mayor
  significa que algo fuerza ese ancho. Entonces `bisect`.
- `bisect`: el culpable es el nodo con `kids=0`; sus ancestros salen porque al
  ocultarlos también desaparece.
- `invisible` sale con código 1 si encuentra algo.
- `states`: el estado activo de pestañas y similares hay que provocarlo a mano;
  axe solo ve el que viene seleccionado.

Dos reglas de las animaciones de entrada: no ocultes nunca un contenedor entero,
y excluye lo que viva dentro de un carrusel.

## Causas típicas de scroll horizontal

- Un flex-item sin `min-width: 0` con texto que no se parte. Se arregla en el
  contenedor.
- Un elemento a sangre con márgenes negativos fuera del contenedor que pone el
  padding. Se envuelve en un elemento con ese padding.
- `overflow-x: hidden` en la raíz lo tapa pero no lo arregla. Busca la causa con
  `bisect`.

## Gotchas

- Mide después de hidratar: baja en tramos con pausa y espera a un selector que
  solo exista hidratado.
- Recorre sin volver arriba, o `invisible` da falsos positivos.
- No encadenes `| head`: el proceso muere antes de escribir. Redirige a fichero.
- Comprueba que el puerto sirve la aplicación que crees.
- Tras tocar el layout raíz, reinicia el servidor de desarrollo.
- Si sale la página de error por chunks dinámicos, reintenta.
- Mata el servidor de desarrollo por PID, nunca con `pkill`.

## Relacionado

- `/device-loop` — la app real en un dispositivo físico
- `/render-loop` — iterar sobre una salida renderizada
- `/ui-behaviour` — que los controles hagan algo útil
