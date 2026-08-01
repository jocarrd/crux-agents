---
name: code-health
description: Medir la salud estructural de un repo y su tendencia: duplicación real, funciones largas con ramas, anidamiento, exports que nadie importa, dependencias sin usar y qué ficheros se remueven más. Guarda una línea base para poder responder si el código está peor que la última vez. Usa cada cierto tiempo, antes de planificar un refactor, al heredar un repo, o cuando lleves una temporada generando mucho código con agentes.
---

# code-health

La revisión de código mira **el diff**. Esto mide **el conjunto**, que es lo que
nadie mira y lo que se erosiona despacio.

Importa especialmente cuando se trabaja con agentes: el patrón medido en el
sector es que el código generado dispara la **duplicación**, porque el modelo
tiende a repetir una solución en vez de buscar la que ya existe en el repo. No
se nota en ningún diff concreto; se nota tres meses después.

## Uso

```bash
node <directorio-de-esta-skill>/scripts/health.mjs [ruta] [--save] [--tests] [--top N]
```

Sin dependencias: solo necesita ficheros y git. Funciona sobre TypeScript,
JavaScript, Python, Go, Rust, Java y Ruby.

`--save` guarda la línea base en `.crux-health.json`. **Ese es el punto**: a
partir de ahí la pregunta deja de ser "¿está bien esto?" —que no tiene respuesta
sin discutir umbrales— y pasa a ser **"¿está peor que la última vez?"**, que sí
la tiene.

Los tests quedan fuera por defecto. Su duplicación es en buena parte legítima
—el mismo montaje repetido— y ahoga la del código de producción, que es la que
importa. Con `--tests` se incluyen.

## Qué mide y cómo interpretarlo

**Duplicación.** Bloques de lógica repetidos, normalizados para que no dependan
del formateo. Solo cuenta lo que tiene lógica de verdad: los imports
multilínea, los objetos literales y los comentarios están filtrados, porque si
no dominan el informe y lo vuelven inservible.

> Un bloque en dos sitios puede ser casualidad. **En cuatro es una función que
> falta.** Si además está en cuatro ficheros del mismo módulo, la función falta
> en ese módulo.

**Funciones largas y con ramas.** Largo no es lo mismo que complejo: un
catálogo de datos de 1.500 líneas no es un problema. Por eso solo se reporta lo
que es largo **y** tiene ramificación. Lo que se busca es "esto hace demasiadas
cosas", no "esto ocupa mucho".

**Anidamiento.** Profundidad máxima por fichero. A partir de siete niveles, el
lector deja de sostener el estado mental.

**Exports que nadie importa.** Candidatos a código muerto. **Cuidado**: pueden
ser API pública consumida desde fuera, puntos de entrada o cosas usadas por
reflexión. Es una lista para revisar, no para borrar.

**Dependencias declaradas y sin usar.** Suelen ser restos de algo que se probó.
Cada una es superficie de ataque y tiempo de instalación.

**Ficheros más removidos.** Del historial de git. Por sí solo no dice nada
malo: lo que se toca mucho suele ser el corazón del repo.

## La lectura que de verdad importa

Cruza dos listas: **un fichero que aparece a la vez en "más removido" y en "muy
anidado" o "función larga" es donde el refactor se paga solo.** Se toca mucho y
cuesta tocarlo. Refactorizar algo complejo que nadie toca es tiempo tirado.

## Cadencia

No es una skill de cada día. Tiene sentido:

- Cada cierto número de semanas, para ver la tendencia.
- Antes de planificar un refactor, para elegir **dónde** en vez de por
  intuición.
- Al heredar un repo, junto con `/repo-map`.
- Después de una temporada de generar mucho código.

Guarda la línea base la primera vez. Sin ella el informe es una foto, y lo
valioso es la película.

## Qué hacer con el resultado

1. **Duplicación primero.** Es lo más barato de arreglar y lo que más deuda
   evita: extraer una función es de riesgo bajo y efecto inmediato.
2. **Después el cruce removido × complejo.** Ahí va el refactor de verdad.
3. **Los huérfanos y las dependencias, en una pasada de limpieza aparte.** Son
   ruido de fondo, no urgencia.
4. **Y lo que no vas a arreglar, ni lo mires.** Un informe que produce una lista
   de deseos que nadie ejecuta deja de leerse.

## Anti-patterns

- **Perseguir el cero.** Algo de duplicación es sana; abstraer dos cosas que se
  parecen hoy pero evolucionan distinto es peor que repetirlas.
- **Borrar exports huérfanos sin comprobar.** Es la forma más rápida de romper
  un consumidor externo.
- **Medir sin línea base.** Los números absolutos invitan a discutir umbrales;
  la tendencia no admite discusión.
- **Convertirlo en una puerta de CI.** Bloquear un commit por una métrica
  estructural genera trampas, no calidad. Esto informa decisiones, no las toma.

## Relacionado

- `/ship` — la revisión del diff, aguas arriba de esto
- `/repo-map` — orientarse en un repo, complementario al heredarlo
- `/write-tests` — antes de refactorizar lo que este informe señale
