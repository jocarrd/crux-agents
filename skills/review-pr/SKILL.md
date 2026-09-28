---
name: review-pr
description: Revisar el código de una propuesta ya abierta con criterio de revisor y no de autor: si el diff hace lo que dice, si el arreglo está completo, si los tests prueban comportamiento, si encaja con lo que el repo ya hace, y qué deuda deja. Clasifica el riesgo y lanza en paralelo solo los revisores especialistas que el diff pide (seguridad, datos, rendimiento, interfaz). Usa justo después de abrir una propuesta de cambio, antes de pedir revisión humana, cuando heredes la propuesta de otra sesión, o cuando el cambio lo haya escrito un agente.
---

# review-pr

La revisión entre abrir la propuesta y que alguien la mire. `/ship` pregunta si
está listo lo que hiciste; esto pregunta si es correcto y completo lo que se
propone. El porqué de cada regla está en
`<directorio-de-esta-skill>/references/por-que.md`.

## Desde un contexto independiente

Se revisa desde un contexto distinto del que escribió el cambio: una revisión
aislada si el entorno la permite, o una sesión nueva con **solo el diff y la
descripción de la propuesta**, sin el historial.

## Qué se pone delante

```bash
crux review
```

Reúne commits, diff contra la base, la propuesta con sus comprobaciones y
señales objetivas (código sin tests, trabajo a medias, credenciales aparentes,
dependencias, ficheros que crecen). Además, lee **las convenciones del repo** en
su documentación.

## Riesgo y especialistas

`crux review` termina con el riesgo y los especialistas que merece
(`scripts/review-scope.sh`):

| Riesgo | Cuándo | Qué se lanza |
| ------ | ------ | ------------ |
| bajo | sin código, o 30 líneas de código o menos sin nada sensible | solo la revisión general |
| medio | código normal | la general + los especialistas que toque |
| alto | seguridad, datos, o más de 500 líneas | la general + los especialistas que toque |

Especialistas: **seguridad**, **datos**, **rendimiento** e **interfaz**, cada
uno con su guía en `specialists/`. Se lanzan **solo los que el script nombra**,
tres como máximo, **en paralelo y cada uno en un contexto aislado**, con el
diff, la descripción y su guía, nada más. No sustituyen la revisión general. Si
el script no nombra a ninguno y ves algo que lo pide, se lanza ese uno y se dice
por qué.

**Rigor** (`rigor` en `crux.json`):

- `light` (y repos sin `crux.json`): especialistas solo con riesgo alto; se
  fusiona sin preguntar lo que no sea riesgo alto.
- `normal` (por defecto): lo de arriba.
- `strict`: sin el atajo de las 30 líneas, y nunca se fusiona solo.

**Quién fusiona** lo dice la línea `fusión:`, y manda sobre tu criterio. Solo se
fusiona sin preguntar un cambio que sea **solo texto** (`.md`, `.txt`, licencias,
`.gitignore`) en un proyecto propio. CSS, estilos, plantillas y tests cuentan
como código. En un repo de cliente, siempre una persona.

## El recorrido

En este orden:

1. **Fidelidad.** ¿El diff hace lo que dice la propuesta, y solo eso? Ficheros
   que no vienen a cuento, formato mezclado con lógica, restos de depuración.
2. **Completitud del arreglo.** ¿Por dónde más entra esto? Otro comando que
   acepte la misma entrada sin validar, otro sitio que haga el mismo cálculo.
3. **Correctitud.** Casos límite, vacíos, errores no gestionados, condiciones
   invertidas, orden de operaciones. Cada sospecha se reproduce antes de
   escribirla.
4. **Tests.** ¿Existen? ¿**Fallan sin el arreglo**? (revierte el código, corre,
   restaura). ¿Prueban comportamiento o fijan la implementación? ¿Cubren el
   camino de fallo?
5. **Consistencia.** Utilidades reinventadas, dos formas de lo mismo, nombres
   fuera de la convención, dependencias nuevas para algo resuelto.
6. **Legibilidad.** Se entiende a la primera qué hace y por qué. Sobran los
   comentarios que narran; faltan los que explican un porqué que no se deduce.
7. **Deuda y ruido.** Duplicación, abstracciones de más, ficheros que crecen.
8. **Superficie sensible.** Secretos, entradas sin validar hacia rutas o
   consultas, permisos, dependencias nuevas.

## Cómo se escribe un hallazgo

```
fichero:línea — qué ocurre
por qué importa: la consecuencia concreta
qué lo arregla: la línea, no el sermón
```

Cada hallazgo se confirma (reproducido, o citando la línea que lo demuestra)
antes de salir. **Los que no se confirman se caen.**

## Qué se hace con ellos

- **Confirmado y claro:** se arregla en la misma rama, con su test, y `/ship`
  otra vez.
- **Confirmado y discutible** (diseño o alcance): se publica en la propuesta y
  decide quien revisa.
- **Dudoso:** no se publica; se comprueba primero.

**Dos rondas de arreglo como mucho.** Cada ronda revisa solo lo que el arreglo
toca. Si tras la segunda queda un hallazgo grave, se para y se cuenta qué queda
abierto y qué se intentó.

## Contárselo a quien decide

La revisión termina contada, no solo en la propuesta. Por hallazgo, en este
orden: **qué está mal** (una frase), **qué cambiarías** (fichero, línea,
arreglo; o que ya está hecho) y **por qué importa** (la consecuencia real).

- Ordenado por lo que costaría si pasa.
- Separando lo arreglado de lo que necesita decisión.
- Diciendo qué se revisó sin encontrar nada, y qué no se revisó.
- Sin hallazgos, se cuenta igual: qué se miró y con qué criterio.

## Anti-patterns

- Revisar en el mismo hilo que escribió el código.
- Resumir el diff y llamarlo revisión.
- Publicar sospechas sin reproducir.
- Mirar solo lo que el diff toca.
- Aprobar porque los tests pasan.
- Dejarlo para después de fusionar.
- Dejar los hallazgos solo en la propuesta.

## Relacionado

- `/ship` — la puerta del autor, aguas arriba
- `/flow` — el ciclo completo; esto es su paso 6a
- `/root-cause` — cuando un hallazgo necesita depurarse
- `/write-tests` — el test que falta cuando el hallazgo es real
