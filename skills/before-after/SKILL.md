---
name: before-after
description: Enseñar a quien decide el antes y el después de un cambio visual —la versión publicada a la izquierda, la nueva a la derecha y una barra roja en medio, en escritorio, tablet y móvil— y no subir nada hasta su visto bueno; con el sí, esas capturas acompañan a la PR. Usa cuando termines un cambio que se ve —rediseño, pulido, página nueva, responsive—, cuando te pidan "enséñame cómo queda antes de subirlo", "pásame el antes y el después" o "quiero verlo en el móvil", o antes de subir la rama de algo que toca interfaz.
---

# before-after

Un cambio visual está terminado cuando lo ha visto **quien decide**. Esta skill
le prepara el antes y el después, pegados, en tres tamaños de pantalla, para
decidir en un minuto desde el móvil. El porqué de cada paso y de cada gotcha:
`<directorio-de-esta-skill>/references/por-que.md`.

## Cuándo usar

- El diff toca algo que se ve: interfaz, estilos, una página nueva, un gráfico.
- Antes de proponer el cambio (`crux workspace finish`), después de `/ship`.
- Otra vez si, tras enseñarlo, hubo cambios: por comentarios de la persona o de
  la revisión de la propuesta.

## Cuándo no usar

- Cambios que no se ven: lógica, backend, datos, documentación.
- Iterar tú sobre un detalle mientras maquetas: eso es `/render-loop`.
- Medir la desviación contra un diseño oficial: eso es `/visual-diff`.

## El procedimiento

### 1. Decidir qué se enseña

Las páginas que toca el diff, **no todo el sitio**, y en tres anchos: escritorio
(1440), tablet (820) y móvil (390). Si hay piezas que no son páginas —un vídeo,
un PDF, una imagen descargable—, se generan y se enseñan también, como fichero.

### 2. Capturar las dos versiones con el mismo script

El **antes**, de lo publicado si la base es lo desplegado; si no, la base en
otro puerto desde el checkout principal. El **después**, de la rama, mejor con
el build de producción en local. Los dos con el mismo script y los mismos datos.

```bash
mkdir -p ~/.cache/visual-test && cd ~/.cache/visual-test
[ -d node_modules/playwright-core ] || npm i playwright-core >/dev/null 2>&1
cp "<directorio-de-esta-skill>/scripts/capture.mjs" .

node capture.mjs --base https://<publicado> --head http://localhost:<puerto> \
  --paths /,/<otra> --widths 1440,820,390 --out <carpeta> \
  --hide '<selectores de avisos de cookies, chat y capas flotantes>'
```

### 3. Montar las comparativas

```bash
python3 "<directorio-de-esta-skill>/scripts/compose.py" <carpeta> --lang es
```

Deja en `<carpeta>/compare/` un montaje por página y ancho (antes a la
izquierda, después a la derecha, barra roja), en tramos de unos 3.000 px y en
WebP.

### 4. Mirarlas antes de mandarlas

Abre cada montaje. Lo que veas mal se arregla antes de enseñar; distingue los
artefactos de captura (ver Gotchas).

### 5. Enseñarlas y esperar

Se mandan a quien decide por el canal de la conversación, con una línea de qué
cambió. Los de escritorio y móvil primero; el de tablet si cambia algo propio.
**No se sube nada** —ni push, ni propuesta— hasta que diga que sí.

### 6. Anotar el sí

```bash
crux visual approve <carpeta>/compare --note "<lo que se revisó, en una frase>"
```

Guarda el recibo `.crux-visual` con el commit sobre el que se capturó. Si
después entra otro commit, las capturas ya no enseñan lo que se propone: se
vuelve al paso 2.

### 7. Proponer

`crux workspace finish` lee el recibo y añade a la propuesta una sección
«Antes y después». Según el perfil del proyecto:

| `visual.publish` | Qué hace |
| ---------------- | -------- |
| `branch` (por defecto) | Sube las imágenes a una rama aparte que nunca se fusiona (`visual.branch`, `crux-review` por defecto) y las enlaza en la propuesta |
| `none` (repos de cliente) | Solo la nota de revisión, sin imágenes y sin dejar nada nuestro en su repo |

Si la propuesta ya está abierta y se vuelve a enseñar tras comentarios:
`crux visual pr <número>` reemplaza esa sección en lugar de añadir otra.

## Gotchas

- **Una gráfica vacía en la captura** suele ser la animación reiniciada al
  cambiar el tamaño de la ventana; `capture.mjs` ya espera. Compruébala en el
  navegador antes de llamarlo bug.
- **Lo que carga al entrar en pantalla** necesita recorrer la página; el script
  lo hace.
- **Con servidor de desarrollo, el Chrome del sistema puede no pintar;** mejor
  el build de producción.
- **Avisos de cookies, chat y capas flotantes:** `--hide` con sus selectores,
  que van en el adaptador del proyecto.
- **Los elementos fijos salen al final** de la captura completa: son de la
  captura, no del diseño.
- **Solo las páginas que tocó el diff:** veintisiete imágenes no las revisa
  nadie.

## Anti-patterns

- Mandar solo el escritorio.
- Enseñar el después sin el antes.
- Subir "para que lo vea en la propuesta": lo que se enseña para aprobar va
  antes de subir.
- Publicar capturas de un commit anterior (no se esquiva borrando el recibo).

## Relacionado

- `/ship` — la puerta que va antes; su puerta 7 es la que ve el agente
- `/visual-test` — inspeccionar una página en los dos anchos mientras se trabaja
- `/render-loop` — iterar un detalle de maquetación
- `/visual-diff` — medir contra un diseño oficial
- `/flow` — dónde encaja esto en el ciclo
