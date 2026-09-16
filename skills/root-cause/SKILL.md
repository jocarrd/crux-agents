---
name: root-cause
description: Depurar con disciplina: reproducir antes de tocar nada, medir en vez de suponer, estrechar el espacio de búsqueda por bisección y separar el síntoma de la causa. Usa cuando algo falla y no sabes por qué, cuando un arreglo anterior no aguantó, cuando el fallo solo pasa en producción, o cuando estés a punto de proponer una solución sin haber entendido el problema.
---

# root-cause

El fallo más común al depurar es **proponer el arreglo antes de entender el
problema**. Suele funcionar a la primera lo justo para esconder la
causa real, que reaparece un mes después con otra cara.

## La regla

> **No se propone un arreglo hasta poder explicar por qué falla y demostrarlo.**

Si no puedes reproducirlo o señalar la línea, todavía estás investigando,
aunque tengas una teoría muy convincente.

## 1. Reproducir

Sin reproducción no hay depuración: hay adivinanza. Y tampoco puedes saber si
tu arreglo funcionó, porque no tienes con qué comprobarlo.

Escribe **el caso mínimo que falla**: qué entrada, qué estado previo, qué
secuencia. Si solo falla a veces, esa intermitencia es un dato, no un
obstáculo: apunta a tiempo, orden, concurrencia o caché.

Si no reproduce en local pero sí en otro entorno, la diferencia entre los dos
entornos **es la pista principal**. Enumérala: versiones, variables, datos,
permisos, latencia, zona horaria.

Si solo falla en producción, **se empieza por lo que producción ya sabe**:
`/prod-signals` resume sus logs y dice qué error, cuántas veces y desde cuándo.
Es un dato más fiable que el relato de quien lo vio.

## 2. Medir, no suponer

Cada afirmación durante la depuración necesita una prueba detrás. "Debe de
estar llegando mal el parámetro" no vale: imprime el parámetro.

Instrumenta el camino completo antes de mirar el detalle: qué entra, qué sale
de cada capa, qué se llamó y con qué. La mayoría de los bugs difíciles se
resuelven al ver que **el dato ya venía mal tres capas antes**.

## 3. Estrechar por bisección

La técnica más rentable y la que menos se usa.

- **En el tiempo**: si antes funcionaba, encuentra el commit que lo rompió.
  Bisecar sobre el historial da la respuesta en unos pocos pasos.
- **En el espacio**: parte el sistema por la mitad y comprueba de qué lado está
  el fallo. Repite. Diez capas se recorren en tres o cuatro pruebas.
- **En los datos**: reduce la entrada hasta que quitar una cosa más haga
  desaparecer el fallo. Lo que queda es la causa.

## 4. Separar síntoma de causa

Pregunta "¿y por qué pasa eso?" hasta que la respuesta sea algo que puedas
cambiar y que explique **todos** los síntomas observados, no solo el que
reportaron.

Señales de que te has quedado en el síntoma:

- El arreglo es un caso especial para una entrada concreta.
- Añade una comprobación defensiva sin saber quién manda mal el dato.
- No sabrías decir por qué el bug no salía antes.
- Funciona pero no sabes explicar por qué.

Ese último es el más peligroso: **si no sabes por qué funciona, no sabes cuándo
va a dejar de funcionar**.

## 5. Escribir lo aprendido

Dos salidas, y las dos importan:

**Un test que reproduce el bug**, escrito antes del arreglo y que falle antes
de aplicarlo. Es la única prueba de que entendiste el problema.

**Una nota donde haga falta**, si la causa fue algo que no se deduce del
código: un comportamiento raro de una dependencia, una configuración de
infraestructura, un supuesto que resultó falso. Eso no cabe en un comentario y
se pierde si no se escribe en la documentación del proyecto.

## Cuando el sistema no es tuyo

Si el código pertenece a otro, o hay alguien más que decide qué es un bug:
**registra mediciones, no diagnósticos**. Anota qué se midió, cómo
reproducirlo y qué pregunta abre. No declares algo como error ni concluyas qué
está mal sin la validación de quien tiene autoridad para decirlo.

Y distingue siempre lo medido de lo leído en documentación previa: la
documentación describe la intención del momento en que se escribió, no el
estado actual.

## Anti-patterns

- **Cambiar cosas a ver si se arregla.** Si funciona, no sabrás por qué; si no,
  habrás ensuciado el terreno.
- **Arreglar el primer síntoma.** Suele haber una causa común detrás de tres.
- **Dar por buena la propia teoría sin comprobarla.** La primera teoría es
  gratis; comprobarla cuesta dos minutos.
- **Depurar con la caché caliente.** La mitad de los fallos que no reproducen
  vienen de un estado previo que no has limpiado.

## Relacionado

- `/write-tests` — el test de regresión que cierra el bug
- `/prod-signals` — lo que dicen los logs de producción, resumido
- `/ship` — la puerta que evita que el arreglo rompa otra cosa
