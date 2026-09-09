---
name: explain-plan
description: Presentar una propuesta técnica para que se pueda decidir sobre ella: qué cambia, qué se comprobó para llegar ahí, qué se rompe si es un error, qué alternativas se descartaron y qué queda sin resolver. Incluye cuándo usar tabla, cuándo diagrama y cuándo prosa. Usa antes de implementar algo que no es trivial, cuando haya varias formas razonables de hacerlo, o cuando quien decide no es quien va a escribir el código.
---

# explain-plan

Un plan se escribe **para que alguien pueda pararlo a tiempo**.

> **Un buen plan se mide por lo que tarda quien lo lee en detectar que está
> mal.**

Un plan que dice "voy a cambiar el formato de la clave de caché" se rechaza en
cinco segundos con "no, eso rompe las claves existentes, usa un prefijo
versionado". El mismo arreglo después de escribir el código es un diff que
revisar y probablemente revertir.

## Cuándo usar

- Antes de implementar algo que toca más de un módulo o que no es reversible
  en cinco minutos.
- Cuando hay varias formas razonables de hacerlo.
- Cuando quien decide no es quien va a escribir el código.

## Cuándo no usar

- Cambios acotados y evidentes. Un plan para arreglar una errata es ruido.
- Cuando el trabajo ya está hecho: entonces lo que toca es `/adr`, que registra
  lo decidido, no lo propuesto.

## Las cinco secciones

Ninguna está por costumbre. Si una no aporta en tu caso, se quita.

### 1. Qué cambia

Una frase, y después el alcance real: qué ficheros o módulos se tocan, qué
queda fuera. El alcance es lo primero que se discute, así que va arriba.

### 2. Por qué así — la traza

**Es la sección que casi nadie escribe y la que hace útil el plan.**

No la conclusión: **qué comprobaste para llegar a ella**. Qué miraste, qué
encontraste, qué te hizo descartar el camino obvio. Quien lee no tiene que
reconstruir tu razonamiento ni fiarse de él: lo verifica.

Y tiene un efecto secundario que vale más que el documento: **obliga a la
especificidad**. Cuando escribes "comprobé X y resultó Y" descubres las veces
que en realidad no lo comprobaste.

### 3. Qué se rompe si me equivoco

El reverso y su coste. Lo que distingue una decisión de ida y vuelta de una de
un solo sentido, y por tanto cuánto había que pensarla.

Si algo se puede deshacer con un `git revert`, dilo: baja el listón de la
discusión. Si implica una migración de datos, dilo más alto todavía.

### 4. Alternativas descartadas

Con **el motivo**, no la lista. "Se descartó X" no sirve; "se descartó X porque
obliga a mantener dos formatos en paralelo durante toda la transición" sí.

Es lo que evita repetir el mismo análisis dentro de tres meses, y lo que
permite que alguien diga "ese motivo ya no aplica, reabramos".

### 5. Lo que no sé

Preguntas abiertas, explícitas. **Un plan que finge cubrirlo todo es peor que
uno que señala sus huecos**, porque el hueco sigue ahí y ahora además está
escondido.

## Qué forma darle a cada cosa

| Contenido | Forma | Por qué |
| --------- | ----- | ------- |
| Comparar opciones | **Tabla** | Permite decidir de un vistazo, que es el objetivo |
| Flujo con varios actores o pasos | **Diagrama de secuencia** | La prosa obliga a reconstruir el orden mentalmente |
| Dependencias entre piezas | **Grafo** | Lo que se ve de un golpe y no se ve leyendo |
| Estados y transiciones | **Diagrama de estados** | |
| El porqué, los tradeoffs, los riesgos | **Prosa** | No cabe en una tabla sin perder el matiz |
| Cifras y medidas | **En el texto, no en un gráfico** | Tres números no necesitan ejes |

Un diagrama transporta la misma información con bastante menos coste que la
prosa equivalente — **cuando hay algo que dibujar**.

## Anti-patterns

- **El diagrama decorativo.** Un flujo de cuatro cajas obvias no aporta nada y
  hace parecer que el plan es más profundo de lo que es. Dibuja lo que no se ve.
- **El plan que es una lista de pasos.** "1. modificar X, 2. añadir Y" no se
  puede rechazar, porque no dice nada discutible. Si no hay un porqué, no hay
  plan.
- **La plantilla completa por costumbre.** Es el modo de fallo documentado de
  los RFC: se rellenan secciones que no aportan, el nivel de detalle sube, y la
  gente deja de leerlos. Cinco secciones cortas se leen; doce, no.
- **Detalle de implementación en el plan.** Los nombres de variable y la firma
  exacta de las funciones van en el código. El plan es para decidir, no para
  programar sobre papel.
- **Presentar solo la conclusión.** Sin la traza, aprobar es confiar. Y confiar
  no es revisar.

## Relacionado

- `/adr` — registrar lo ya decidido, aguas abajo de esto
- `/ship` — la puerta que revisa la implementación del plan aprobado
