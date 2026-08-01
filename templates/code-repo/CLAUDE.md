# {{REPO}} — {{TAGLINE}}

Parte del proyecto **{{PROJECT}}**.

<!-- crux:begin — bloque generado por `crux link`. Escribe lo tuyo debajo del cierre. -->

## Dónde está la documentación

- De este repo: `../{{DOCS}}/repos/{{REPO}}/`
- Decisiones que afectan solo a este repo: `../{{DOCS}}/repos/{{REPO}}/decisions.md`
- Decisiones que cruzan varios: `../{{DOCS}}/decisions/index.md`

No vive documentación aquí dentro. Si vas a escribirla, va allí.

## Cómo se trabaja aquí

| Momento | Qué invocar |
| ------- | ----------- |
| Entras y no conoces el repo | `/repo-map` |
| Vas a lanzar varias tareas a la vez sobre él | `/workspace` |
| Algo falla y no sabes por qué | `/root-cause` |
| Vas a commitear | `/ship` |
| Terminas la sesión | `/end-session` |

`/ship` es la que más veces se pasa por alto y la que más cuesta saltarse: pasa
los tests, lee el diff, revisa, simplifica, vuelve a pasarlos y solo levanta el
entorno si el cambio se ve desde fuera.

## Reglas que no se negocian

- **Si cambias código que invalida una doc, la actualizas en el mismo turno.**
  No después, no en otro commit.
- **Las notas de proyecto y las referencias van a git**, no a la memoria local
  del agente. Esa queda para lo relativo a la persona.
- Conventional commits, cuerpo de 100 caracteres por línea, sin
  `Co-Authored-By` y sin emojis.
- Sin comentarios que narren lo que el código ya dice. El porqué va en la
  documentación.

Reglas completas y contexto transversal: @../{{DOCS}}/CLAUDE.md

<!-- crux:end -->
