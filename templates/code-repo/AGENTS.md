# AGENTS.md — {{REPO}}

{{TAGLINE}}

Este repo forma parte de **{{PROJECT}}**.

<!-- crux:begin — bloque generado por `crux link`. Escribe lo tuyo debajo del cierre. -->

**Antes de trabajar, lee `../{{DOCS}}/AGENTS.md`**: ahí está el contexto
transversal del proyecto (arquitectura, convenciones, operaciones).

## Dónde está la documentación

- De este repo: `../{{DOCS}}/repos/{{REPO}}/`
- Decisiones que afectan solo a este repo: `../{{DOCS}}/repos/{{REPO}}/decisions.md`
- Decisiones que cruzan varios: `../{{DOCS}}/decisions/index.md`

No vive documentación aquí dentro. Si vas a escribirla, va allí.

## Cómo se trabaja aquí

**Ante cualquier tarea de desarrollo, el ciclo es `flow`**: entender, aislar
el espacio, planificar, desarrollar, pasar la puerta, proponer y cerrar. Esa
skill explica el orden y por qué ese orden.

Los pasos, si necesitas ir directo a uno:

| Momento | Qué invocar |
| ------- | ----------- |
| Entras y no conoces el repo | `repo-map` |
| Vas a empezar a trabajar | `workspace` — tu rama y tu entorno, sin pisar a nadie |
| Antes de tocar código | `explain-plan` |
| Algo falla y no sabes por qué | `root-cause` |
| Vas a commitear | `ship` |
| Has terminado | `workspace finish` — sube la rama y abre la propuesta |
| Cierras la sesión | `end-session` |

## Reglas que no se negocian

- **Antes del primer fichero de una tarea, abre las convenciones del proyecto.**
  Están escritas; el fallo no es que falten, es leerlas después de escribir el
  código, cuando ya solo sirven para reordenar. La puerta 4 de `/ship` las
  vuelve a poner delante, pero ahí ya es rework.
- **Si cambias código que invalida una doc, la actualizas en el mismo turno.**
- **Las notas de proyecto y las referencias van a git**, no a memoria local.
- Conventional commits, cuerpo de 100 caracteres por línea, sin
  `Co-Authored-By` y sin emojis. La descripción de una propuesta de cambio
  tampoco lleva firma de la herramienta ni línea de "generado con".
- Sin comentarios que narren lo que el código ya dice.

<!-- crux:end -->
