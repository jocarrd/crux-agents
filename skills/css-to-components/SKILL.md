---
name: css-to-components
description: Mover estilos de una hoja CSS global a los componentes que los usan sin cambiar el diseño ni un píxel, midiendo la geometría antes y después en vez de comparar capturas. Usa cuando un fichero CSS global haya crecido hasta ser el sitio donde de verdad se decide el aspecto, cuando quieras adoptar utilidades o un design system sobre una interfaz que ya existe, o cuando te pidan ordenar el CSS "sin tocar el diseño".
---

# De CSS global a componentes

Trasladar estilos sin que se muevan. El éxito no es que quede bonito: es que
**los valores computados sean los mismos** antes y después.

## Cuándo usar

- Una hoja global concentra el aspecto de la aplicación y crece sola.
- Se quiere adoptar utilidades o un design system sobre una interfaz existente.
- El encargo dice explícitamente "sin cambiar el diseño".

## La regla que lo sostiene

**Mide números, no píxeles.**

Comparar capturas parece la verificación obvia y es la que más tiempo hace
perder. Da rojos por cosas que no son el cambio:

- **Contenido que varía solo**: listas que paginan según el alto disponible,
  registros que crecen con el uso, cualquier pantalla con datos vivos.
- **Animaciones**: una animación en bucle impide que dos capturas coincidan.
- **Preferencias del navegador**: un navegador sin cabeza puede arrancar con
  alto contraste o movimiento reducido activados, y entonces se compara un modo
  que nadie ve.
- **Los arreglos legítimos** que se pidan por el camino: en cuanto uno entra,
  las referencias caducan y el resto de rojos deja de significar nada.

Medir la geometría computada no falla por nada de eso, y cuando falla dice qué
propiedad se movió.

## El procedimiento

### 1. Medir el original

Antes de escribir una sola clase, y en los anchos donde el diseño cambia
(típicamente uno ancho, uno intermedio y uno de móvil):

```js
const caja = (sel) => {
  const el = document.querySelector(sel);
  const r = el.getBoundingClientRect();
  return [r.x, r.y, r.width, r.height].map(Math.round).join(",");
};
```

Guarda también las propiedades que dan forma: `display`, `position`, `padding`,
`minHeight`, `gridTemplateColumns`, `borderRadius`, `zIndex`. Esa lista es el
contrato.

### 2. Averiguar el valor efectivo

**El valor que manda no es el primero que aparece en el fichero.** Es habitual
que al final de una hoja larga haya un bloque que redeclara componentes ya
definidos arriba y los pisa. Migrar el primero produce un cambio silencioso.

El script `scripts/reglas.py` lista **todas** las reglas que tocan un selector,
en orden y con la media query que las envuelve:

```bash
python3 scripts/reglas.py ruta/al/fichero.css "nombre-del-bloque"
```

### 3. Traducir

Copia los valores tal cual. **No es el momento de unificar**: un tamaño suelto
se conserva suelto, con su nombre, y se anota. Unificar es otro trabajo y otra
decisión, casi siempre de diseño y no de desarrollo.

Los cortes responsive se traducen literalmente (`max-[900px]:`) aunque no
coincidan con los del framework. Cambiarlos mueve el diseño.

### 4. Retirar las reglas

Solo las del bloque migrado, y con cuidado del **selector agrupado**:

```css
.cabecera-pagina p,
.cabecera-panel p { ... }
```

Es una sola regla que sirve a dos clases. Borrarla entera al migrar una deja a
la otra sin estilo. Cuando el selector es mixto se **poda**: se quitan las
partes migradas y se conservan las vivas.

### 5. Volver a medir

Mismo script, mismos anchos. Los números tienen que coincidir. Si no coinciden,
el que sobra dice dónde mirar.

### 6. Si hay que deshacer

**Siempre con `git checkout`.** Reinsertar reglas a mano cambia el orden de la
cascada aunque el contenido sea idéntico, y rompe pantallas en silencio. Borrar
es seguro y reversible; reconstruir a mano, no.

## Antes de empezar, comprobar dos cosas

**Que las clases del design system se apliquen de verdad.** Una sintaxis de una
versión anterior del framework puede no generar ninguna regla, y entonces el CSS
global es lo único que pinta. Se comprueba buscando la utilidad en la hoja
compilada, no en el código fuente.

**Qué reglas de elemento alcanzan el bloque.** Un selector como
`.contenedor h1` tiene más especificidad que cualquier utilidad y le gana
siempre. O se saca esa regla a los componentes —lo que afecta a toda la
aplicación de golpe— o el caso concreto necesita forzarse, y eso se anota como
excepción.

## Lo que no se migra

- La geometría de página impresa (`@page`) y las declaraciones de fuentes: no
  tienen forma de utilidad.
- Los resets que aplican a todo el árbol (`*`, `prefers-reduced-motion`,
  `prefers-contrast`).
- Lo que sirva de **gancho** a otra capa: si la hoja de impresión selecciona
  elementos por su clase, quitarles la clase la rompe. Antes de migrar, se
  sustituye esa lista de clases por un gancho único aplicado a los contenedores.

El objetivo no es cero CSS, que sería una meta tonta. Es **cero CSS que compita
con el design system**: una regla de página impresa no compite con nada; un
tamaño de fuente decidido a quinientas líneas del componente que lo usa, sí.

## Al terminar

Queda un inventario que antes no se podía hacer: todos los valores sueltos que
la hoja escondía, ahora con nombre y ubicación. Tamaños fuera de escala, pesos
intermedios, sombras escritas a mano. **Ese inventario es el material para la
conversación con diseño**, y es la parte que de verdad unifica el sistema.

## Relacionado

- `/visual-test` — inspección visual y auditoría de accesibilidad
- `/visual-diff` — medir contra una referencia de diseño
- `/root-cause` — cuando un valor no coincide y no se sabe por qué
