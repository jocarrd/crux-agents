---
name: teach
description: Enseñar algo a lo largo de varias sesiones, anclado en el código del proyecto y no en ejemplos de manual: un directorio con el motivo por el que se aprende, las fuentes de confianza, las lecciones y el registro de lo ya aprendido. Usa cuando el usuario pida que le expliques una tecnología para aprenderla de verdad y no para salir del paso, cuando diga "no termino de entender", "explícame bien", "quiero aprender" o "hazme una guía", y cuando haga la misma pregunta de fondo por segunda vez.
---

# teach

Una explicación en el chat se entiende mientras se lee y se evapora al cerrar
la sesión. A la semana siguiente vuelve la misma pregunta con otras palabras.

Esta skill convierte esas explicaciones en un espacio con estado: un directorio
donde queda por qué se está aprendiendo, de qué fuentes, qué lecciones se han
dado y qué se ha aprendido de verdad. Cada sesión continúa la anterior.

## La regla que la diferencia de un tutorial

> **Todo se explica sobre el código que el usuario tiene delante.**

Un tutorial de Prisma enseña `model User { id Int }`. Una lección útil enseña
el `catalogSnapshot` de *su* esquema, con el problema real que resuelve y la
regla que solo vive en un comentario. Lo primero se olvida porque no se usa; lo
segundo se queda porque es el código que va a tocar mañana.

Antes de escribir ninguna lección, lee el repo: el esquema, los ficheros de
configuración, los sitios donde ya aparece el concepto. Si el proyecto tiene
docs repo, léelo también. El ejemplo sale de ahí.

## El espacio de trabajo

El directorio actual es el espacio. Su estado vive en estos ficheros:

- **`MISION.md`** — por qué quiere aprender esto. Sin esto no se empieza: es lo
  que decide qué entra en cada lección y qué sobra. Si está vacío, la primera
  tarea es preguntarlo.
- **`FUENTES.md`** — las fuentes de confianza, con enlace y una línea de qué
  aporta cada una. La documentación oficial, el artículo del que lo diseñó, la
  especificación. **No te fíes de lo que creas recordar**: búscalo y cítalo.
- **`lecciones/NNNN-<nombre>.md`** — las lecciones, numeradas.
- **`referencia/`** — lo destilado: chuletas, tablas, diagramas. Lo que se
  consulta después, ya sin leer la lección entera.
- **`aprendido/NNNN-<nombre>.md`** — el registro de lo aprendido. Son a la
  enseñanza lo que un ADR a la arquitectura: lo no obvio, lo que costó, lo que
  hubo que corregir. De aquí sale qué se puede enseñar después.
- **`NOTAS.md`** — preferencias del usuario y apuntes de trabajo.

## Fluidez y retención

Hay que separar dos cosas que se confunden:

- **Fluidez**: recuperar algo en el momento, con la explicación delante.
- **Retención**: tenerlo dentro dentro de seis meses.

La fluidez da una sensación de dominio que es falsa. Quien acaba de leer una
explicación clara cree que lo sabe, y una semana después no. El objetivo es la
retención, y se consigue con dificultad deliberada:

- **Recuperación**: que tenga que sacarlo de memoria antes de enseñárselo.
  Una pregunta al principio de la lección siguiente vale más que un resumen.
- **Espaciado**: repartir en el tiempo en vez de una sesión larga.
- **Entrelazado**: mezclar temas relacionados en la práctica, no bloques puros.

## La lección

Una lección enseña **una** cosa acotada, atada a la misión, y se termina de una
sentada. La memoria de trabajo es pequeña: una lección larga es una lección que
no se completa.

Cada lección lleva:

- Un ejemplo sacado del código del proyecto, con su ruta.
- Una cosa que el usuario pueda hacer al terminar y antes no podía.
- **Una fuente primaria** para ampliar, la mejor que hayas encontrado.
- Un recordatorio de que puede preguntar: el agente es el profesor, no el PDF.

Cuando el usuario prefiera leerlo en otro formato, el destino natural en este
entorno es un documento de Claude Docs por tema, que se puede seguir editando
entre sesiones. Para lo que se imprime o se manda por correo, la convención del
usuario es PDF en A5.

Pasa la skill `/redaccion` antes de entregar cualquier lección larga.

## El cierre de cada sesión

Antes de terminar:

1. Escribe el registro en `aprendido/` de lo que costó o sorprendió.
2. Destila a `referencia/` lo que se va a volver a consultar.
3. Di cuál es el siguiente paso y por qué toca ese.

Si el tema da para más de dos o tres sesiones, regístralo con `crux task` para
que sobreviva al cierre de la sesión.

---

*Adaptada de la skill `teach` de
[mattpocock/skills](https://github.com/mattpocock/skills), licencia MIT. El
anclaje en el código del proyecto y el destino de las lecciones son propios.*
