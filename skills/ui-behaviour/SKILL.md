---
name: ui-behaviour
description: Comprobar que los controles de una interfaz hacen algo útil y son alcanzables, no solo que existan y se vean bien. Pulsa cada botón desde un estado limpio y mide qué cambia, recorre la interfaz con el tabulador buscando lo que no se alcanza y las trampas de foco, y verifica los estados que solo existen al interactuar. Usa cuando termines una pantalla con filtros, pestañas, tablas ordenables, formularios o diálogos; cuando heredes una interfaz que no conoces; o cuando alguien pregunte si un botón sirve para algo.
---

# ui-behaviour

La inspección visual dice si algo **se ve** bien. Esta dice si **hace** algo y si
se puede **llegar** a ello.

Son preguntas distintas y fallan por separado: un botón puede tener el contraste
perfecto, el área táctil correcta, y no estar conectado a nada — o estarlo y no
poder alcanzarse con el teclado.

## Cuándo usar

- Terminas una pantalla con controles: filtros, pestañas, ordenación, paginación,
  formularios, diálogos.
- Heredas una interfaz y quieres saber qué está vivo y qué es decorado.
- Sospechas de un control concreto: «¿esto sirve para algo?».

## Precondiciones

Las mismas que `/visual-test`: Chrome del sistema, `playwright-core` en un
directorio de caché, y la aplicación corriendo en local.

## Qué se comprueba

Seis familias. Las tres primeras se automatizan; las tres últimas piden criterio.

**1. Que el control haga algo.** Pulsar y medir qué cambia.

**2. Que se pueda alcanzar con el teclado.** Tabular por la interfaz: todo
control operable debe recibir foco, en un orden que siga la lectura, y con un
anillo de foco visible. Un control que solo responde al ratón no existe para
media población.

**3. Que los diálogos se comporten.** Al abrirse, el foco entra; mientras está
abierto, no se escapa; `Escape` cierra; al cerrarse, el foco vuelve al control
que lo abrió. Un diálogo visualmente cerrado que retiene el foco es un fallo.

**4. Que los estados que solo existen al interactuar aguanten.** Hover, foco,
activo, deshabilitado. Aquí es donde fallan las auditorías automáticas: miden el
reposo. Si al pasar el ratón se rellena de color, hay que medir el contraste
*ahí*. Si solo hay una pestaña activa a la vez, la auditoría solo ve la que
viene por defecto y las demás pueden estar fallando.

**5. Que lo que solo aparece al pasar el ratón tenga otra vía.** Una acción que
se revela en hover no existe en una pantalla táctil ni con teclado.

**6. Que los estados vacíos y de error digan algo.** Filtrar hasta cero
resultados, enviar un formulario incompleto, cortar la red. La interfaz debe
decir qué pasa, no quedarse en blanco.

## El método para la familia 1

**Enumera** los controles visibles y habilitados. **Toma una huella** de lo que
el usuario vería cambiar —el contenido de las primeras filas de cada tabla, sus
cabeceras, qué lleva la marca de activo, los contadores, cuántas fichas hay—; no
sirve comparar el HTML entero, que cambia por motivos que no importan. **Pulsa,
espera, vuelve a tomarla.** Lo que no cambia ninguna señal es sospechoso.
**Investiga los sospechosos uno a uno**: ahí está el trabajo.

## Las dos trampas que dan falsos positivos

Las dos me han pasado, y las dos me llevaron a punto de reportar bugs que no
existían.

**Encadenar clics sin recargar.** Si pulsas «Oceanía» y luego, más abajo, otro
«Oceanía», el segundo no cambia nada — porque ya estabas en Oceanía. **Recarga
antes de cada control** que quieras juzgar de verdad. Es lento; hazlo solo con
los sospechosos de la primera pasada.

**Selectores ambiguos entre componentes.** Una página puede tener dos botones
«Reset», uno por herramienta, y un «Rank» que pertenece a una tabla y no a la
otra. Si el selector no está acotado, pulsas uno y mides el otro, y concluyes
que no funciona. **Acota siempre a la raíz del componente.**

## Lo que sí es correcto que no cambie nada

- Un control **ya activo**: la pestaña seleccionada, el filtro puesto.
- Un **reset sin nada que resetear**.
- Un control cuyo efecto está **fuera de la huella** que mides: si abre un
  diálogo, navega fuera o cambia algo que no observas, amplía la huella en vez
  de darlo por muerto.

## Uso

```bash
cd ~/.cache/visual-test
node ui-behaviour.mjs sweep    http://localhost:3000/ruta
node ui-behaviour.mjs probe    http://localhost:3000/ruta "Reset" --scope .rt-root
node ui-behaviour.mjs keyboard http://localhost:3000/ruta
```

`sweep` hace la pasada rápida y lista los sospechosos. `probe` recarga, acota al
componente y pulsa uno solo dos veces, enseñando la huella en cada paso — que es
como se distingue un botón muerto de uno que coincide con el estado por defecto.
`keyboard` tabula por la página y reporta los controles que no reciben foco, los
que no tienen anillo visible, y los saltos de orden.

Para el contraste en hover, `/visual-test states`.

## Qué reportar

Un control sin efecto **no es un bug hasta que descartas las dos trampas**. Di
qué pulsaste, desde qué estado y qué señal miraste. «El botón X no hace nada»
sin eso es casi siempre un error del que mide.

## Relacionado

- `/visual-test` — la otra mitad: que se vea bien, que quepa, que contraste, y
  que ninguna animación deje contenido invisible
- `/e2e` — cuando el flujo merezca una prueba que se quede
