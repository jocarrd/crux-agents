---
name: ship
description: Puerta de calidad antes de commitear, graduada según lo que toca el diff: clasificar el cambio para saber qué puertas aplican, comprobar en verde los tests afectados, leer el diff completo, revisar correctitud, buscar la implementación más simple, pasar la suite entera, validar en el entorno real solo si el cambio toca superficie observable, revisar si alguna documentación quedó desalineada y commitear. Usa cuando termines un trozo de trabajo y vayas a commitear, o cuando quieras una revisión seria de lo que llevas hecho.
---

# ship

Cadena de puertas antes de commitear. Se para en cuanto una falla. El porqué de
cada regla está en `<directorio-de-esta-skill>/references/por-que.md`; léelo si
dudas de alguna o vas a proponer una excepción.

## 0. Qué puertas hacen falta

Antes que nada:

```bash
bash <directorio-de-esta-skill>/scripts/diff-scope.sh
```

Dice qué puertas aplican, qué tests correr en la 1 y si hay que levantar el
entorno. Lo decide el clasificador, no tu criterio.

| Lo que toca el diff | Puertas |
| ------------------- | ------- |
| Solo texto (documentación, licencias, `.gitignore`) | 2, 8, 9 |
| Código que no se ve desde fuera | 1 a 6, 8, 9 |
| Superficie observable: interfaz, API, datos, dependencias, integración | todas |

## 1. Sanidad

Pasa los tests afectados (línea `tests:` del clasificador), no la suite entera,
antes de mirar nada. Si ya estaban rojos, no es tu diff: dilo y para.

Si el informe trae `artefactos:` (capturas, volcados, temporales sueltos en la
raíz), sácalos del stage o añádelos al `.gitignore`. Nunca se commitean.

## 2. Leer el diff

Entero. Comprueba que hace exactamente lo que se pretendía. Para y pregunta si
hay ficheros que no venían a cuento, formato mezclado con lógica, código muerto
o restos de depuración.

## 3. Correctitud

Casos límite, nulos, errores no gestionados, condiciones invertidas,
concurrencia. Si hay revisión automática, va aquí.

## 4. Convenciones

```bash
bash <directorio-de-esta-skill>/scripts/conventions.sh
```

Lista los documentos de convenciones que aplican y señales concretas (literales
repetidos, tipos en ficheros de constantes, catálogos redeclarados). Las señales
son heurísticas; **abrir los documentos que lista no es opcional**.

## 5. Calidad

Solo ahora: ¿hay una forma más simple? Reutilizar lo que existe, abstracción a
la altura correcta, nombres que dicen lo que hacen.

## 6. Regresión

La suite entera, después de los arreglos de 3 a 5.

**Un test que ya existía y se pone rojo no se edita para que pase.** Para y
dilo. Solo se cambia si quien decide confirma que ese comportamiento ya no se
quiere.

## 7. Realidad, solo si la puerta 0 lo pide

| Lo que toca el diff | Qué validar |
| ------------------- | ----------- |
| Interfaz | Verlo en los viewports que importen; después, `/before-after` para que lo apruebe quien decide |
| API | Llamar a los endpoints afectados, no solo sus tests |
| Datos | Que la migración aplique **y revierta** |
| Dependencias | Que arranque desde cero, no desde tu caché |

Levanta el entorno en el espacio de trabajo de la tarea.

## 8. Deriva de la documentación

Si el cambio invalida alguna documentación, se actualiza en el mismo turno. El
aviso del clasificador es una señal, no un veredicto.

## 9. Commit

Conventional commit, imperativo y minúscula, con un cuerpo que explique el
porqué. Un tipo de cambio por commit.

## Dejar constancia

Las comprobaciones se ejecutan a través de crux, que anota el resultado real:

```bash
crux ship gate                  # lo que declara quality.gate del contrato
crux ship run -- <comando>      # una comprobación suelta
crux ship seal                  # después del commit
```

`seal` se niega si algo quedó en rojo y cierra el recibo contra HEAD. `crux
workspace finish` no abre la propuesta sin ese recibo. `finish --skip-gate`
existe solo para obedecer a quien decide, nunca para ahorrarse un paso.

`.crux-ship` va en el `.gitignore` del repo.

## Antes de publicar la propuesta

```bash
crux ship body <fichero con el cuerpo>
```

Busca la firma de la herramienta y, en perfil `client-repo`, cualquier mención
de nuestro tooling.

## Anti-patterns

- Decidir las puertas a ojo en vez de con la puerta 0.
- Pasar las nueve a un cambio de documentación.
- Empezar por la 3: sin la 1 no sabes si el rojo es tuyo.
- Cerrar la 4 sin abrir el documento.
- Simplificar (5) antes de verificar (3).
- Saltarse la 6 porque el cambio era pequeño.
- Dar por pasada la 7 sin haber visto la pantalla ni llamado al endpoint.
- Commitear con una puerta en rojo.

## Relacionado

- `/workspace` — el entorno aislado de la puerta 7
- `/visual-test` — la revisión visual de la puerta 7
- `/end-session` — el cierre de la sesión
