---
name: ui-tells
description: Medir sobre la página renderizada los marcadores que delatan una interfaz generada por un modelo: rejillas de tres tarjetas iguales, antetítulos en versalita por todas partes, el punto medio como separador universal, ventanas de navegador dibujadas con divs, cifras redondas de relleno y verbos de folleto. Separa los fallos objetivos, que se arreglan, de los indicios, que son criterio de quien diseña. Usa cuando pidan iterar o mejorar una interfaz ya construida, cuando alguien diga que una pantalla «parece hecha por IA», «queda genérica» o «parece una plantilla», o antes de enseñar una página a alguien de fuera.
---

# ui-tells

Una interfaz generada se reconoce por su forma antes que por su contenido, igual
que un texto generado. Los marcadores son pocos, concretos y se pueden contar.
Esta skill los mide sobre la página ya renderizada, que es donde se ven.

Es la hermana de `redaccion` para las pantallas, y comparte su regla principal:
**cuenta y localiza, no arregla**. Decidir si cada caso sobra te toca a ti.

## Cuándo usar

- Te piden iterar o pulir una interfaz que ya existe.
- Alguien dice que una pantalla «parece hecha por IA», «queda muy genérica» o
  «parece una plantilla».
- Antes de enseñar una página a un cliente o publicarla.

## Cuándo no usar

- **Como puerta automática.** No la metas en `quality.gate`: se ejecutaría en
  cada `crux ship` y acabarías peleándote con ella en cambios que no tocan la
  interfaz. Se invoca a mano, cuando toca.
- Para accesibilidad o scroll horizontal. Eso es `visual-test`, que ejecuta
  axe-core de verdad.
- Para comprobar que los controles hacen algo. Eso es `ui-behaviour`.
- Para decidir la dirección de diseño. Esto mide, no diseña.

## Precondiciones

Chrome del sistema y `playwright-core` en el directorio desde el que ejecutas.
Igual que `visual-test`:

```bash
npm i playwright-core
export CHROME_BIN=/usr/bin/google-chrome   # si no está en la ruta habitual
```

La página tiene que estar servida, en local o en producción.

## Uso

```bash
node scripts/ui-tells.mjs revisar <url> [url...]   # el recuento
node scripts/ui-tells.mjs detalle <url>            # cada caso con su texto
```

Sale con código 1 si hay algún fallo objetivo, así que sirve dentro de un script
si alguna vez lo quieres encadenar.

## Los dos grupos, y por qué están separados

**Fallos objetivos.** No dependen del gusto de nadie: o el titular cabe en la
primera pantalla o no cabe.

| Marcador | Por qué es un fallo |
| -------- | ------------------- |
| Raya larga en texto visible | El mismo tic que caza `redaccion`, aquí en la interfaz |
| Titular o llamada fuera de la primera pantalla | Quien entra no ve qué es esto ni qué hacer |
| Navegación de más de 80px o en dos líneas | Se come la pantalla y delata que no se pensó el ancho |
| Etiqueta de botón partida en dos líneas | Se lee mal y suele significar que el texto es largo |
| `100vh` en vez de `100dvh` | En móvil el contenido salta al esconderse la barra de direcciones |

**Indicios.** Cuentan algo real, pero puede ser exactamente lo que pide el
contenido. Se informan aparte y no puntúan.

Rejilla de tres columnas iguales, densidad de antetítulos en versalita, líneas
con más de un punto medio, antetítulos numerados (`001 · Capabilities`),
ventanas de navegador dibujadas con divs sin ninguna imagen dentro, textos de
«scroll», etiquetas de versión en la primera pantalla, nombres de relleno
(Acme, John Doe, Lorem), cifras falsamente redondas y verbos de folleto
(impulsar, potenciar, unleash, seamless).

Esa separación es la misma que hace `redaccion` con la raya larga y los dos
puntos, y por el mismo motivo: una medición automática no distingue un remate
de una explicación.

## Cómo leer el resultado

La carga son los fallos objetivos. **Cero es lo normal**, y cualquier cosa por
encima se arregla antes de entregar.

Los indicios no tienen umbral. Sirven para mirar dos veces: si la portada tiene
cinco rejillas de tres tarjetas iguales, el problema probablemente sea que todas
las secciones se parecen entre sí, y no ninguna de ellas por separado.

## Gotchas

Tres falsos positivos ya resueltos en el script (cómo y por qué, en
`<directorio-de-esta-skill>/references/por-que.md`): no reintroduzcas la
comparación de alturas para las etiquetas partidas, la ventana falsa con una
imagen dentro ni las filas de navegación por coordenada exacta. La comprobación
de `100vh` solo ve el CSS del propio dominio.

## Anti-patterns

**Convertir los indicios en reglas.** Si empiezas a prohibir las rejillas de
tres columnas en todas partes, has cambiado un diseño genérico por otro.

**Medir sin mirar.** La skill no ve la composición, que suele ser la razón real
de que algo «parezca de IA». Pásala, pero abre la página.

**Adoptar una estética ajena.** Los umbrales de aquí son neutros a propósito.
Los que dependen del estilo (tipografías, paletas, simetría) van en las
convenciones de cada proyecto, no en el kernel.

## Relacionado

- `redaccion` — el mismo método para el texto.
- `visual-test` — accesibilidad real, scroll horizontal, contraste.
- `ui-behaviour` — que los controles hagan algo.
- `render-loop` — iterar sobre una salida renderizada.
