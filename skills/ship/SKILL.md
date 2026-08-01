---
name: ship
description: Puerta de calidad antes de commitear, graduada según lo que toca el diff: clasificar el cambio para saber qué puertas aplican, comprobar en verde los tests afectados, leer el diff completo, revisar correctitud, buscar la implementación más simple, pasar la suite entera, validar en el entorno real solo si el cambio toca superficie observable, revisar si alguna documentación quedó desalineada y commitear. Usa cuando termines un trozo de trabajo y vayas a commitear, o cuando quieras una revisión seria de lo que llevas hecho.
---

# ship

Cadena de puertas antes de commitear. Cualquiera puede abortar el proceso: la
gracia no es pasar por todas, es no seguir cuando una falla.

## 0. Qué puertas hacen falta

**Primero esto, antes de la puerta 1.**

```bash
bash <directorio-de-esta-skill>/scripts/diff-scope.sh
```

Clasifica el diff y responde tres cosas: **qué puertas aplican**, **qué tests
correr en la 1** y **si hace falta levantar el entorno**.

| Lo que toca el diff | Puertas |
| ------------------- | ------- |
| Solo texto —documentación, licencias, `.gitignore` | 2, 7, 8 |
| Código que no se ve desde fuera | 1 a 5, 7, 8 |
| Superficie observable: interfaz, API, datos, dependencias, integración | todas |

No es una concesión, es aritmética: **si esto cuesta lo mismo para una errata
que para un cambio de esquema, dejarás de invocarlo en dos semanas** y la
puerta habrá fracasado. Un cambio de solo documentación no tiene código que
pueda estar incorrecto ni tests que puedan regresar; hacerle las ocho puertas
no lo verifica más, solo lo encarece.

Lo decide el clasificador y no tu criterio en el momento: a ojo todo parece
pequeño, y así es como se salta justo la que hacía falta.

## 1. Sanidad

Pasa los tests **antes de mirar nada** — los afectados por el diff, no la suite
entera. El clasificador los dice en su línea `tests:`.

Aquí solo se responde a una pregunta: **¿el rojo ya venía de antes?** Para eso
basta lo afectado. La suite completa es la puerta 5; correrla en las dos es
pagar la más cara dos veces para responder dos preguntas distintas.

Si ya estaban rojos, no es cosa de tu diff: dilo y para. Es la puerta más
barata y la que más tiempo ahorra, porque evita depurar durante media hora un
fallo que ya venía de antes.

## 2. Leer el diff

Entero, no en diagonal. Lo que se busca aquí no son bugs todavía, sino **la
intención**: qué se pretendía cambiar y si el diff hace exactamente eso.

Señales de que hay que parar y preguntar: ficheros tocados que no venían a
cuento, cambios de formato mezclados con cambios de lógica, código muerto que
se ha quedado, restos de depuración.

## 3. Correctitud

Revisión centrada en fallos: casos límite, valores nulos, errores no
gestionados, condiciones invertidas, concurrencia. Si tienes una revisión
automática disponible, este es su sitio.

## 4. Calidad

Ahora, y no antes, la pregunta de si hay una forma más simple. Reutilización de
lo que ya existe en el proyecto, altura de abstracción correcta, nombres que
dicen lo que hacen.

El orden importa: **simplificar código incorrecto es tirar el trabajo**.

## 5. Regresión

**Ahora sí, la suite entera**, después de los arreglos de las puertas 3 y 4.
Los arreglos también rompen cosas, y rompen precisamente lo que no estabas
mirando: por eso aquí no vale el subconjunto de la puerta 1.

## 6. Realidad, solo si hace falta

La puerta 0 ya dijo si aplica. Levantar el entorno siempre es lo que mata la
costumbre; no levantarlo nunca es lo que deja pasar los fallos que los tests no
ven.

| Lo que toca el diff | Qué validar |
| ------------------- | ----------- |
| Interfaz | Verlo. Revisión visual en los viewports que importen |
| API | Llamar a los endpoints afectados, no solo sus tests |
| Datos | Que la migración aplique **y revierta** |
| Dependencias | Que arranque desde cero, no desde tu caché |

Si el proyecto tiene espacios de trabajo aislados, levanta el entorno en el
suyo: así no chocas con tu propio servidor de desarrollo.

## 7. Deriva de la documentación

¿Este cambio invalida alguna documentación? Si sí, se actualiza **en el mismo
turno**, no después. Es la disciplina que sostiene todo el estándar.

El clasificador avisa cuando el diff toca superficie y no hay documentación
tocada. Es una señal, no un veredicto: muchos cambios no afectan a ninguna doc.

## 8. Commit

Conventional commit, en imperativo y minúscula, con un cuerpo que explique **el
porqué** — el qué ya está en el diff. Si el cambio es de varios tipos, son
varios commits.

## Dejar constancia

Después del commit, anota qué se verificó:

```bash
printf '%s\n' "$(git rev-parse HEAD)" > .crux-ship
```

No es burocracia: **`crux workspace finish` lo lee para no abrir una propuesta
de código que no ha pasado la puerta**. Si el commit cambia después, la marca
deja de coincidir y hay que volver a pasarla, que es exactamente lo que debe
ocurrir.

Añade `.crux-ship` al `.gitignore` del repo: es estado local, no del proyecto.

## Anti-patterns

- **Saltarse la puerta 0 y decidir a ojo.** Acaba siempre en el mismo sitio:
  "esto es pequeño" y la puerta que hacía falta sin pasar.
- **Pasar las ocho a un cambio de documentación.** No lo verifica más, solo
  encarece la puerta hasta que dejas de pasarla.
- **Empezar por la puerta 3.** Sin la 1 no sabes si el rojo es tuyo.
- **Simplificar antes de verificar.** Puertas 4 después de 3, siempre.
- **Saltarse la 5 porque "el cambio era pequeño".** Los arreglos rompen cosas.
- **Marcar la 6 como hecha sin haber mirado nada.** Si no viste la pantalla ni
  llamaste al endpoint, esa puerta no está pasada.
- **Commitear con una puerta en rojo y "ya lo arreglo".** Entonces la cadena no
  es una puerta, es un adorno.

## Relacionado

- `/workspace` — el entorno aislado donde levantar la puerta 6
- `/visual-test` — la revisión visual de la puerta 6 cuando toca interfaz
- `/end-session` — el cierre de la sesión, aguas abajo de esto
