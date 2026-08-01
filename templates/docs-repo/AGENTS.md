# AGENTS.md — {{PROJECT}}-docs

Documentación transversal de **{{PROJECT}}**. Es el contexto canónico del
proyecto para cualquier agente de código.

Este archivo es un **índice**: lee solo la sección que necesitas para la tarea
actual, no todo a ciegas.

---

## Cómo se trabaja aquí

Antes de buscar dónde está algo, esto es lo que hay que hacer y cuándo:

| Momento | Qué invocar |
| ------- | ----------- |
| Entras a un repo que no conoces | `/repo-map` |
| Vas a lanzar varias tareas a la vez sobre el mismo repo | `/workspace` |
| Algo falla y no sabes por qué | `/root-cause` |
| Vas a añadir o arreglar comportamiento | `/write-tests` |
| **Vas a commitear** | **`/ship`** |
| Se ha tomado una decisión que no queda en el código | `/adr` |
| Terminas la sesión | `/end-session` |

Las dos que más se pasan por alto son `/ship` y `/end-session`, y son las que
sostienen el resto: la primera evita que entre trabajo roto, la segunda evita
que se pierda lo aprendido.

> **Cómo carga este contexto cada agente:**
> - **Claude Code** lo lee como `CLAUDE.md` (symlink a este fichero) y resuelve
>   los `@-import` de los repos hermanos automáticamente.
> - **Otros agentes** leen este `AGENTS.md`. Cada repo hermano tiene también un
>   `AGENTS.md` que apunta aquí.

---

## Cuándo leer qué

**Vas a tocar código de un repo concreto**
- Documentación específica del repo → `repos/<repo>/`
- Decisiones que afectan solo a ese repo → `repos/<repo>/decisions.md`

**Vas a tomar o revisar una decisión que cruza varios repos**
- Registro de ADRs → `decisions/index.md`
- Formato y cómo añadir uno → `decisions/README.md`

**Quieres entender cómo está organizada esta documentación**
- El estándar completo vive en el kernel: `crux/STANDARD.md`
- Versión y perfil aplicados aquí: `crux.json`

<!-- Añade secciones a medida que aparezcan: architecture/, conventions/,
     operations/, topics/<tema>/ -->

---

## Skills

Los procedimientos transversales (documentación, decisiones, sesiones,
verificación) viven en el kernel y están disponibles como `/<nombre>`.

Las específicas de {{PROJECT}} viven en `.claude/skills/project/` de este repo.
Cuando aparezcan, se listan aquí con su disparador, para que los agentes que no
leen frontmatter puedan descubrirlas.

---

## Reglas duras

- **La documentación específica de un repo va en `repos/<repo>/`**, no dentro
  del repo de código. Lo transversal va en `architecture/`, `conventions/`,
  `operations/` o `topics/<tema>/`.
- **Sincronización código ↔ doc:** al modificar código que invalida una doc de
  aquí, se actualiza en el mismo turno.
- **Las notas de proyecto y las referencias van a git, no a memoria local del
  agente.** La memoria local queda para lo relativo a la persona.
- **Los cambios en este repo se commitean y pushean al terminar.**
- **Conventional commits**, body de 100 caracteres por línea como máximo.
- **Sin `Co-Authored-By`. Sin emojis.**
