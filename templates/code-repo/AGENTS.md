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

Los procedimientos del proyecto están en `../{{DOCS}}/AGENTS.md` y en el kernel
del estándar. Si tu agente no los reconoce como comandos, ábrelos como
documentos y sigue el procedimiento:

| Momento | Procedimiento |
| ------- | ------------- |
| Entras y no conoces el repo | `repo-map` |
| Vas a lanzar varias tareas a la vez sobre él | `workspace` |
| Algo falla y no sabes por qué | `root-cause` |
| Vas a commitear | `ship` |
| Terminas la sesión | `end-session` |

## Reglas que no se negocian

- **Si cambias código que invalida una doc, la actualizas en el mismo turno.**
- **Las notas de proyecto y las referencias van a git**, no a memoria local.
- Conventional commits, cuerpo de 100 caracteres por línea, sin
  `Co-Authored-By` y sin emojis.
- Sin comentarios que narren lo que el código ya dice.

<!-- crux:end -->
