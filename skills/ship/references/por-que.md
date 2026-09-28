# Por qué la puerta es así

El procedimiento está en `SKILL.md`. Aquí está el motivo de cada regla, para
cuando haya que decidir si una excepción tiene sentido.

## La puerta se gradúa

Si cuesta lo mismo para una errata que para un cambio de esquema, se deja de
invocar en dos semanas y la puerta fracasa. Un cambio de solo documentación no
tiene código que pueda estar mal ni tests que puedan regresar: pasarle las
nueve puertas no lo verifica más, solo lo encarece.

Lo decide el clasificador porque a ojo todo parece pequeño, y así es como se
salta justo la puerta que hacía falta.

## Sanidad antes que nada, y solo con lo afectado

La puerta 1 responde a una pregunta: ¿el rojo ya venía de antes? Para eso basta
con los tests afectados. La suite entera es la puerta 6; correrla en las dos es
pagar la más cara dos veces para responder dos preguntas distintas. Es la
puerta más barata y la que más tiempo ahorra: evita depurar media hora un fallo
que ya estaba.

Los artefactos sueltos en la raíz los arrastra un `git add -A` sin que los vea
ningún test ni el linter.

## Convenciones antes que calidad, y calidad después de correctitud

Las convenciones se suelen leer después de escribir el código, cuando ya solo
sirven para reordenar. Autoevaluarse el estilo sin abrir el documento siempre
sale que sí: por eso la puerta lista ficheros y no hace preguntas.

Reestructurar dos veces es tirar el trabajo: una convención aplicada después
obliga a mover lo que la puerta de calidad iba a simplificar, y simplificar
código incorrecto también es tirarlo.

## La suite entera al final

Los arreglos de las puertas 3 a 5 también rompen cosas, y rompen justo lo que
no estabas mirando.

Un test que ya existía y se pone rojo suele tener razón, y el diagnóstico no.
Editarlo para que pase borra la única prueba de que el cambio rompe algo.

## Levantar el entorno solo cuando toca

Levantarlo siempre mata la costumbre; no levantarlo nunca deja pasar los fallos
que los tests no ven. En el espacio de trabajo de la tarea no chocas con tu
propio servidor de desarrollo.

## La documentación, en el mismo turno

Es la disciplina que sostiene todo el estándar. Muchos cambios no afectan a
ninguna doc, por eso el aviso del clasificador es una señal y no un veredicto.

## El recibo

Antes, el propio agente escribía un sha después de afirmar que había
verificado. Eso no prueba que verificara: prueba que escribió un sha. Por eso
las comprobaciones pasan por `crux ship run`, que ejecuta el comando y anota
el resultado real, y `finish` exige el recibo sellado contra HEAD.

`crux ship body` existe porque la descripción de la propuesta era el único
artefacto del flujo que no comprobaba nadie, y es el que acaba delante del
cliente.
