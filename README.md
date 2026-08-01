# crux

El *crux* es el paso clave de una vía: el punto del que depende todo lo demás.

Este repo es el **kernel del sistema de trabajo con agentes**. Contiene el
estándar de documentación, las skills transversales, las plantillas y el
tooling que usan todos los proyectos. Se instala una vez por máquina y desde
él se lanzan y se mantienen los repos de documentación de cada proyecto.

No es un repo de documentación de un proyecto. Es lo que los fabrica.

---

## Instalación

```bash
git clone git@github.com:jocarrd/crux.git ~/Proyectos/crux
~/Proyectos/crux/install.sh
```

Eso deja las skills disponibles en Claude Code (`/<nombre>`) y en Codex
(`/<nombre>`), y registra la ruta del kernel en `~/.crux/config` para que
ningún proyecto tenga que saber dónde vive.

## Comandos

| Comando | Qué hace |
| ------- | -------- |
| `crux init <project>` | Crea `~/Proyectos/<project>/<project>-docs` desde las plantillas |
| `crux adopt` | Registra un docs repo que ya existe bajo el estándar |
| `crux add-repo <repo>` | Registra un repo nuevo en un proyecto adoptado |
| `crux link` | Crea y verifica los punteros de los repos de código del proyecto |
| `crux doctor` | Verifica la conformidad de un docs repo con el estándar |
| `crux upgrade` | Re-materializa el kernel en un proyecto a la versión actual |

Todos existen también como skills: `/crux-init`, `/crux-doctor`, etc.

## Las tres capas

| Capa | Qué es | Dónde vive |
| ---- | ------ | ---------- |
| **Kernel** | Estándar, skills transversales, plantillas, tooling | este repo |
| **Proyecto** | Documentación del proyecto y sus skills propias | `<project>-docs/` |
| **Repo** | Punteros de contexto, generados | cada repo de código |

Cada docs repo declara su contrato con el kernel en un `crux.json`:

```json
{
  "crux": "0.1.0",
  "project": "acme",
  "profile": "multi-repo",
  "repos": ["Acme", "acme-engine", "acme-cms"],
  "sections": ["architecture", "conventions", "operations", "topics"]
}
```

## Agentes soportados

El conocimiento se escribe **una vez en markdown neutro**. El instalador lo
materializa para cada agente:

| Pieza | Claude Code | Codex |
| ----- | ----------- | ----- |
| Skill | symlink en `~/.claude/skills/` | stub en `~/.codex/prompts/` |
| Contexto global | `~/.claude/CLAUDE.md` | `~/.codex/AGENTS.md` |
| Contexto de proyecto | `CLAUDE.md` (symlink) | `AGENTS.md` (canónico) |
| Puntero de repo | `CLAUDE.md` con `@-import` | `AGENTS.md` con ruta |

Por eso ninguna skill del kernel menciona herramientas propias de un agente
concreto: describe la acción, no quién la ejecuta.

## Estructura

```
crux/
├── STANDARD.md      el estándar completo — léelo si vas a tocar algo
├── VERSION
├── install.sh       una vez por máquina
├── bin/             init, adopt, add-repo, link, doctor, upgrade
├── lib/             verificadores de paths y utilidades comunes
├── templates/       docs-repo/ y code-repo/
├── profiles/        multi-repo, client-repo
├── adapters/        claude/, codex/
├── skills/          las skills transversales
└── test/            suite del propio kernel
```

## Tests

```bash
./test/run.sh            # todos los casos
./test/run.sh doctor     # solo los que casan con el patrón
```

Cada caso corre en un sandbox aislado con los directorios de agentes
redirigidos: la suite no toca `~/.claude`, `~/.codex` ni `~/Proyectos`.

Dos de los casos vigilan el propio kernel: que ninguna skill se ate a un agente
concreto y que no aparezca el nombre de ningún proyecto. Son los que evitan que
crux vuelva a acoplarse a lo que documenta.

## Estado

Versión `0.1.0`. Proyectos que lo consumen: `acme-docs`, `client-docs`.
