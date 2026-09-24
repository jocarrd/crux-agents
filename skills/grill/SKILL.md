---
name: grill
description: Interrogar a quien decide hasta agotar el árbol de decisiones de un plan, antes de escribir código. Las preguntas salen por rondas, numeradas y con la respuesta que recomiendas; los hechos los busca el agente y las decisiones las toma el usuario. Usa antes de empezar algo que admite varias formas razonables de hacerse, cuando el encargo llega en dos frases y hay que construir mucho, cuando notes que estás rellenando huecos por tu cuenta, o cuando el usuario diga "pregúntame", "hazme preguntas" o "antes de ponerte, aclaremos".
---

# grill

El fallo más caro del desarrollo es construir bien lo que no era. Y casi nunca se detecta al empezar: se detecta al enseñar el resultado.

Un encargo llega con huecos. El agente los rellena solos y en silencio, porque
rellenarlos es más rápido que preguntar. Cada hueco relleno a ojo es una
apuesta, y una sola que salga mal tira el trabajo de la tarde.

Esta skill convierte esos huecos en preguntas antes de que cuesten.

## El árbol y su frontera

Un plan es un árbol de decisiones: cada una abre las que cuelgan de ella. No se
puede preguntar por el formato del PDF si todavía no se sabe si habrá PDF.

La **frontera** son las decisiones cuyos requisitos ya están resueltos: lo que
se puede preguntar **ahora** sin adivinar respuestas que aún no has oído.

Se trabaja por rondas:

1. Calcula la frontera.
2. Pregunta **toda** la frontera de una vez.
3. Espera las respuestas. No avances sin ellas.
4. Las respuestas mueven la frontera hacia fuera y desbloquean lo que dependía
   de ellas. Vuelve al paso 1.

Una pregunta cuya respuesta depende de otra que sigue abierta **en esta ronda**
pertenece a la ronda siguiente. Colarla obliga al usuario a contestar dos veces
o a inventarse una condición.

Termina cuando la frontera queda vacía: todas las ramas visitadas, nada
asumido en silencio.

## Cómo se formula una ronda

Cada pregunta va numerada, con título, y **con la respuesta que recomiendas**.
La recomendación no es opcional: obliga al agente a mojarse y le deja al
usuario decir «sí» en vez de redactar.

```
❓ **P1 — <título corto>**

<el cuerpo de la pregunta: contexto, opciones, lo que cambia según la
respuesta. Puede ocupar varios párrafos>

➡️ <lo que recomiendas y por qué, en una o dos frases>

---

❓ **P2 — <título corto>**

…
```

Si el agente dispone de un control de opciones cerradas, úsalo cuando las
alternativas sean pocas y excluyentes, con la recomendada la primera. Para todo
lo demás, el formato de arriba.

## La regla que sostiene todo

> **Los hechos los busca el agente. Las decisiones las toma el usuario.**

Si una pregunta de la frontera necesita un dato del entorno —qué versión hay
instalada, si ese endpoint existe, cuántas filas tiene esa tabla—, eso **no se
pregunta**: se mira. Preguntarlo gasta el turno del usuario en algo que el
agente resuelve con un comando, y encima obtiene una respuesta de memoria en
vez de un dato.

No bloquees por ello. Una exploración en marcha es un requisito sin resolver,
así que solo esperan las preguntas que cuelgan de ella; el resto de la frontera
se pregunta ya.

## Cuándo parar

Esta skill es cara en turnos del usuario, así que tiene techo:

- **Dos o tres rondas** para un cambio normal. Si vas por la quinta, o el
  encargo es enorme y hay que partirlo, o estás preguntando cosas que deberías
  estar mirando.
- **Ninguna pregunta cuya respuesta no cambie lo que vas a hacer.** Si con las
  dos respuestas posibles construyes lo mismo, la pregunta sobra.
- **Nada de confirmar lo que ya se dijo.** Si está en el encargo, está decidido.

## Después

El resultado de un interrogatorio es un acuerdo, y un acuerdo que solo vive en
la conversación se pierde al cerrar la sesión. Pásalo a donde corresponda:

- `/explain-plan` si hay que presentar la propuesta antes de construirla.
- `/adr` si por el camino se descartó una alternativa por un motivo que no es
  obvio.
- `crux task` si el trabajo va a durar más de una sesión.

No empieces a construir hasta que el usuario confirme que estáis de acuerdo.

---

*El mecanismo del árbol, la frontera y las rondas está adaptado de la skill
`grilling` de [mattpocock/skills](https://github.com/mattpocock/skills),
licencia MIT.*
