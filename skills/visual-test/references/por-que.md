# Los casos detrás de cada comprobación

El procedimiento está en `SKILL.md`. Aquí están los fallos reales que dieron
origen a cada comprobación.

## Por qué playwright-core en una caché

Lanza el Chrome del sistema en vez de descargar un navegador, y se instala en un
directorio de caché junto al script porque ESM resuelve el import relativo al
fichero.

## Las cuatro comprobaciones que nadie más hace

Ni el build, ni el typecheck, ni axe ven ninguna de estas.

**`invisible`.** Una animación de entrada oculta el elemento y lo revela al
entrar en pantalla. Si el disparador se pierde (porque el contenido carga solo
y cambia el alto de la página después de calcular las posiciones), el elemento
se queda en `opacity: 0` para siempre. El HTML está ahí, el test pasa y el
usuario no ve nada. Si a un item se le escapa el disparador se nota poco; si es
una sección entera, es un tramo de página inaccesible. Una diapositiva fuera de
pantalla en horizontal no intersecta nunca, de ahí excluir los carruseles.

**`hydration`.** Un desajuste entre lo que pinta el servidor y el cliente hace
que el framework tire el HTML y repinte entero. Solo se ve escuchando
`pageerror` mientras se recorre.

**`states`.** axe mide el estado en reposo; un botón puede pasar parado y
fallar al pasar el ratón. Si solo hay una pestaña activa a la vez, axe
únicamente ve la seleccionada por defecto.

**`rhythm`.** El caso que lo originó: una regla que no suma el aire de dos
bandas seguidas del mismo fondo, aplicada a una página que pinta su banda con
una clase propia en vez de declararla, y que pierde el aire justo donde el
fondo cambia.

## Por qué `min-width: 0` y no otra cosa

El `min-width: auto` por defecto de un flex-item impide encoger, y manda el
ancho mínimo del contenido. `overflow-x: hidden` en la raíz enmascara el
problema en esa página y reaparece en cualquier otra.

## Los gotchas, con su porqué

- Con islas o carga diferida, un barrido rápido mide el marcado del servidor: el
  mismo bloque puede dar 4.766 px o 1.463 según haya hidratado o no.
- Al volver al principio, lo del fondo queda bajo el pliegue y la comprobación
  de invisibles da un falso positivo.
- `node script | head` mata el proceso por SIGPIPE antes de que escriba, y
  acabas comparando contra datos viejos.
- Un servidor estático no avisa si el puerto ya está ocupado: puedes estar
  midiendo otra aplicación.
- Algunos bundlers en desarrollo no recompilan de forma fiable el layout raíz,
  y medirías el estado anterior.
- Los errores de carga de chunks dinámicos en el primer render headless pueden
  disparar el error boundary; el script calienta dos veces para evitarlo.
- Los decorativos en `position: absolute` dentro de un `overflow: hidden` son
  falsos positivos; el script ya ignora `absolute` y `fixed`.
- Un `pkill` por patrón puede llevarse por delante tu propia shell.
