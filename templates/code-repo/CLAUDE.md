# {{REPO}} — {{TAGLINE}}

Parte del proyecto **{{PROJECT}}**.

<!-- crux:begin — bloque generado por `crux link`. Escribe lo tuyo debajo del cierre. -->

## Dónde está la documentación

- De este repo: `../{{DOCS}}/repos/{{REPO}}/`
- Decisiones que afectan solo a este repo: `../{{DOCS}}/repos/{{REPO}}/decisions.md`
- Decisiones que cruzan varios: `../{{DOCS}}/decisions/index.md`

No vive documentación aquí dentro. Si vas a escribirla, va allí.

## Cómo se trabaja aquí

**Ante cualquier tarea de desarrollo, el ciclo es `/flow`**: entender, aislar
el espacio, planificar, desarrollar, pasar la puerta, proponer y cerrar. Esa
skill explica el orden y por qué ese orden.

Los pasos, si necesitas ir directo a uno:

| Momento | Qué invocar |
| ------- | ----------- |
| Entras y no conoces el repo | `/repo-map` |
| Vas a empezar a trabajar | `/workspace` — tu rama y tu entorno, sin pisar a nadie |
| Antes de tocar código | `/explain-plan` |
| Algo falla y no sabes por qué | `/root-cause` |
| Vas a commitear | `/ship` |
| Has terminado | `/workspace finish` — sube la rama y abre la propuesta |
| Cierras la sesión | `/end-session` |

`/workspace` es el que evita el problema más caro: dos sesiones sobre el mismo
directorio se pisan los ficheros y mezclan sus cambios en el mismo commit.

## Reglas que no se negocian

- **Si cambias código que invalida una doc, la actualizas en el mismo turno.**
  No después, no en otro commit.
- **Las notas de proyecto y las referencias van a git**, no a la memoria local
  del agente. Esa queda para lo relativo a la persona.
- Conventional commits, cuerpo de 100 caracteres por línea, sin
  `Co-Authored-By` y sin emojis. La descripción de una propuesta de cambio
  tampoco lleva firma de la herramienta ni línea de "generado con".
- Sin comentarios que narren lo que el código ya dice. El porqué va en la
  documentación.

Reglas completas y contexto transversal: @../{{DOCS}}/CLAUDE.md

<!-- crux:end -->
