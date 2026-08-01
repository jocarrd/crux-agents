---
name: ship
description: Puerta de calidad antes de commitear: comprobar que los tests ya estaban en verde, leer el diff completo, revisar correctitud, buscar la implementación más simple, volver a pasar los tests, validar en el entorno real solo si el cambio toca superficie observable, revisar si alguna documentación quedó desalineada y commitear. Usa cuando termines un trozo de trabajo y vayas a commitear, o cuando quieras una revisión seria de lo que llevas hecho.
---

# ship

Cadena de puertas antes de commitear. Cualquiera puede abortar el proceso: la
gracia no es pasar por todas, es no seguir cuando una falla.

## Modos

**Rápido** — puertas 1 a 5, 7 y 8. Es el de por defecto para cambios acotados.

**Completo** — todas, incluida la validación en el entorno real. Para cambios
que tocan superficie observable, antes de desplegar, o cuando el diff es
grande.

Que exista el modo rápido no es una concesión: **si esto tarda doce minutos
siempre, dejarás de invocarlo en dos semanas** y la puerta habrá fracasado.

## 1. Sanidad

Pasa los tests **antes de mirar nada**.

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

Tests otra vez, después de los arreglos de las puertas 3 y 4. Los arreglos
también rompen cosas.

## 6. Realidad, solo si hace falta

```bash
bash <directorio-de-esta-skill>/scripts/diff-scope.sh
```

Clasifica el diff y dice si hace falta levantar el entorno. Levantarlo siempre
es lo que mata la costumbre; no levantarlo nunca es lo que deja pasar los
fallos que los tests no ven.

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
