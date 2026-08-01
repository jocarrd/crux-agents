# El estándar

Este documento define cómo se organiza la documentación y el trabajo con
agentes en cualquier proyecto. Vive en `crux` — el kernel — y es la **única**
fuente canónica. Los proyectos no inventan variantes: consumen esta.

Para bootstrap de un proyecto nuevo: `/crux-init <project>`.

---

## TLDR — lo que tiene que saber un agente

1. **Tres capas**: kernel (`crux`), proyecto (`<project>-docs`), repo (punteros generados).
2. **Layout**: repos hermanos en `~/Proyectos/<project>/`, uno de ellos es `<project>-docs/`.
3. **Doc específica de un repo** vive en `<project>-docs/repos/<repo>/`. Nunca en `<repo>/docs/`.
4. **Doc transversal** vive en `<project>-docs/{architecture,conventions,operations}/` (universales) o `<project>-docs/topics/<tema>/` (del dominio del proyecto).
5. **`crux.json`** en cada docs repo declara versión, perfil y repos. Nada se hardcodea en scripts.
6. **Punteros de cada repo de código**: `AGENTS.md` (canónico) y `CLAUDE.md` (symlink o `@-import`). Cortos, generados, no se editan a mano.
7. **Sync discipline**: al cambiar código que afecta a una doc, se actualiza la doc en el mismo turno.
8. **Auto-memory**: `project` y `reference` van a git (`<project>-docs/`). Solo `user` y `feedback` se quedan locales.
9. **ADRs cross-repo** → `decisions/index.md`. **Single-repo** → `repos/<repo>/decisions.md`.
10. **Markdown links** solo a ficheros dentro del propio docs repo. Referencias a código de repos hermanos, en backticks sin enlazar.
11. **Skills**: las transversales viven en el kernel; las del proyecto en `<project>-docs/.claude/skills/project/`. La frontera la decide el test de la sección "Promoción de skills".
12. **Cierre de sesión**: `/end-session` promueve lo que deba sobrevivir, verifica drift y commitea.

---

## Por qué existe

Un desarrollador trabajando en múltiples proyectos, varios repos por proyecto,
varias máquinas y muchas sesiones con agentes distintos. Sin disciplina
explícita la información se pierde: queda en la cabeza de alguien, en una
conversación cerrada, en una memoria local que no sobrevive el cambio de
máquina, o en un commit body que nadie vuelve a leer.

El estándar tiene un objetivo: **que el conocimiento del proyecto viva en git,
organizado, accesible para humanos y para cualquier agente, y sobreviva todo
cambio de máquina, de sesión o de herramienta.**

---

## Las tres capas

| Capa | Qué contiene | Dónde vive | Quién la edita |
| ---- | ------------ | ---------- | -------------- |
| **Kernel** | El estándar, las skills transversales, las plantillas, el tooling | `crux` | Una vez, para todos los proyectos |
| **Proyecto** | La documentación del proyecto y sus skills propias | `<project>-docs/` | Por proyecto |
| **Repo** | Punteros de contexto | Cada repo de código | Generados; no se editan |

La regla que sostiene el reparto: **si algo cambia cuando cambias de proyecto,
no es del kernel.**

---

## El contrato: `crux.json`

Cada docs repo declara su relación con el kernel en un `crux.json` en la raíz:

```json
{
  "crux": "0.1.0",
  "project": "acme",
  "profile": "multi-repo",
  "repos": ["Acme", "acme-engine", "acme-cms"],
  "sections": ["architecture", "conventions", "operations", "topics"]
}
```

| Campo | Significado |
| ----- | ----------- |
| `crux` | Versión del kernel con la que se materializó este proyecto |
| `project` | Nombre del proyecto, igual que la carpeta padre |
| `profile` | Perfil aplicado (ver siguiente sección) |
| `repos` | Repos de código del proyecto, hermanos del docs repo |
| `sections` | Carpetas opcionales activas |

Ningún script del kernel hardcodea nombres de proyecto ni listas de repos: todo
sale de aquí. Si el fichero falta, el proyecto no está adoptado y `crux doctor`
lo reporta como el primer error.

---

## Perfiles

Un perfil es un conjunto de reglas que cambian según **de quién es el código**,
no según qué hace el proyecto.

### `multi-repo` — proyecto propio con varios repos

El caso por defecto. Varios repos de código hermanos, todos propios. Se generan
punteros en todos, se aplica el ciclo completo.

### `client-repo` — el código es del cliente

El docs repo es propio, pero el repo de código pertenece a un cliente.

- **No se escribe nada fuera del docs repo.** Ni punteros, ni `AGENTS.md`, ni
  carpetas del estándar en el repo del cliente. El agente abre la documentación
  explícitamente.
- **Se registran mediciones, no diagnósticos.** No se declara algo como bug ni
  se concluye qué está mal sin validación del cliente.
- **Toda observación lleva evidencia reproducible**: fichero y línea, comando o
  consulta que la demuestra. Sin evidencia no se escribe.
- **Distinguir lo medido de lo heredado.** La documentación previa describe la
  intención del momento en que se escribió, no el estado actual: verificar
  antes de citarla.

Los perfiles viven en `profiles/<nombre>.json` del kernel y `crux doctor` los
hace cumplir. Un perfil no es prosa en un README: es una regla verificable.

---

## Estructura obligatoria

Un docs repo cumple el estándar si tiene esto:

```
<project>-docs/
├── README.md                 qué es el proyecto y qué repos lo componen
├── AGENTS.md                 entry point canónico para cualquier agente
├── CLAUDE.md                 symlink → AGENTS.md
├── crux.json                 el contrato con el kernel
├── decisions/
│   ├── README.md             cómo se escribe un ADR
│   └── index.md              ADRs cross-repo
└── repos/
    ├── README.md             mapping repo → carpeta
    └── <repo-name>/
        └── README.md         índice del repo
```

Eso es el suelo. Si tienes esto, el proyecto está documentado mínimamente.

## Estructura opcional

Aparecen **cuando el proyecto las necesita**, no antes:

| Carpeta | Cuándo aparece |
| ------- | -------------- |
| `architecture/` | Hay más de un repo y hace falta overview o diagramas cross-repo |
| `conventions/` | Aparecen reglas de código transversales (estilo, testing, git) |
| `operations/` | Hay infraestructura: servidores, cloud, monitorización, despliegues |
| `topics/` | Contenedor de categorías específicas del dominio del proyecto |
| `.claude/skills/project/` | Skills específicas del proyecto |

### `topics/` — lo específico del dominio

Categorías cross-repo que **no** son universales pero sí cruzan varios repos de
**este** proyecto. El nombre lo decide cada proyecto:

```
acme-docs/topics/editorial/          voz del blog, SEO, identidad visual
cocina-sencilla-docs/topics/recipes/  formatos, fotografía, voz culinaria
saas-foo-docs/topics/pricing/         política, descuentos, planes
```

**Dónde va una doc nueva, en tres preguntas:**

1. ¿Aplica a cualquier proyecto multi-repo? → `architecture/`, `conventions/`, `operations/`
2. ¿Solo a este proyecto, pero cruza varios repos suyos? → `topics/<tema>/`
3. ¿Solo a un repo? → `repos/<repo>/`

Así nunca aparece una carpeta suelta en la raíz que parece estándar y no lo es.

---

## Convenciones duras

No se negocian: son las que hacen que el sistema escale a varios proyectos sin
romperse.

### 1. Layout en filesystem

- La carpeta padre del proyecto se llama como el proyecto, en kebab-case.
- Los repos son hermanos directos dentro de ella.
- El docs repo se llama `<project>-docs` y es uno de esos hermanos.

Es obligatorio porque hace que la referencia relativa funcione siempre: cada
repo apunta a `../<project>-docs/` y el agente lo resuelve sin configuración.

El kernel es la excepción: `crux` no es un proyecto, no tiene hermanos y vive
en `~/Proyectos/crux/`.

### 2. Punteros de contexto

Cada repo de código tiene dos punteros equivalentes, **generados por
`crux link`**, nunca escritos a mano:

- `AGENTS.md` — canónico, lo lee cualquier agente.
- `CLAUDE.md` — para Claude Code, con el `@-import` al docs repo.

```markdown
# <Repo> — <una línea de qué hace>

Doc completa en `../<project>-docs/repos/<repo>/`.

Atajos:
- design-system.md  · tokens, patrones
- api.md            · endpoints, contratos

Reglas y conocimiento transversal: @../<project>-docs/CLAUDE.md
```

No vive documentación local en el repo de código.

### 3. Paths dentro de las docs

Los paths son **referencias textuales con backticks**, no enlaces navegables.
Header obligatorio en cada doc:

```
> Paths relativos a la raíz de `<repo-name>/`.
```

| Tipo de enlace | Permitido |
| -------------- | --------- |
| URLs externas | sí |
| Ficheros dentro de este docs repo | sí |
| Ficheros en repos hermanos | no |
| Código (`.ts`, `.tsx`, …) | no |

Los enlaces se rompen al mover ficheros y, sin un build que los valide,
terminan mintiendo. Un path en backticks el agente lo resuelve igual y nunca se
rompe. `lib/check-doc-paths.mjs` verifica los que quedan.

### 4. ADRs

- **Cross-repo** → `decisions/index.md`. **Single-repo** → `repos/<repo>/decisions.md`.
- Mientras haya menos de 30 cross-repo, todos en un solo fichero.
- Plantilla única para ambos niveles, definida en `decisions/README.md`.
- Numeración local a cada ledger. Para citar entre ledgers, prefijo del path:
  `decisions/ADR-013` o `repos/demo-co/ADR-007`.
- Al superseder, marcar `Status: Superseded by <ref>` en el viejo. No se borra.

### 5. Auto-memory del agente

Cuatro tipos: `user`, `feedback`, `project`, `reference`.

- `user` y `feedback` se quedan **locales** — son sobre la persona, no sobre el proyecto.
- `project` y `reference` se **promueven a git** en el mismo turno:
  - Operativa y gotchas → `operations/`
  - Punteros a recursos externos → `operations/` o el README que corresponda
  - Estado del proyecto → `repos/<repo>/notes.md`

### 6. Sincronización código ↔ doc

Cuando se modifica código que afecta a una doc, **se actualiza la doc en el
mismo turno**. No después, no en otro commit. Si el cambio no afecta a ninguna
doc (rename interno, test, refactor invisible), no se toca nada.

La proximidad física entre código y doc ya no la da el filesystem: la da esta
disciplina.

### 7. Commits

- Conventional commits (`feat:`, `fix:`, `chore:`, `docs:`, `refactor:`…)
- Subject en minúscula e imperativo
- Body de 100 caracteres por línea como máximo
- Sin `Co-Authored-By`
- Sin emojis, salvo que la voz del fichero lo justifique

---

## Multi-agente

El conocimiento se escribe **una vez, en markdown neutro**. Lo que cambia entre
agentes es solo cómo se carga, y de eso se encarga `install.sh`.

| Pieza | Claude Code | Codex |
| ----- | ----------- | ----- |
| Skill | symlink en `~/.claude/skills/<nombre>` | stub en `~/.codex/prompts/<nombre>.md` |
| Contexto global | `~/.claude/CLAUDE.md` | `~/.codex/AGENTS.md` |
| Contexto de proyecto | `CLAUDE.md` (symlink) | `AGENTS.md` (canónico) |
| Puntero de repo | `CLAUDE.md` con `@-import` | `AGENTS.md` con la ruta |

**Regla dura:** ninguna skill del kernel menciona herramientas propias de un
agente concreto. Se describe la acción a realizar, no quién la ejecuta. Es lo
que permite que el mismo fichero sirva a los dos.

**Consecuencia práctica:** Claude descubre las skills por el `description` del
frontmatter; Codex no lo interpreta. Por eso cada `SKILL.md` repite su "cuándo
usar" en el cuerpo, y el `AGENTS.md` del docs repo lista las skills con su
disparador.

---

## Skills

### Kernel o proyecto

- **Kernel** — describe una manera de trabajar que sobrevive al cambio de
  proyecto: gestionar documentación, decisiones, sesiones, despliegues sin CI,
  verificación visual.
- **Proyecto** — interactúa con la infraestructura concreta: sus servidores,
  sus cuentas cloud, los datos de su producto, su voz editorial.

### Promoción de skills

Para decidir si una skill del proyecto merece subir al kernel:

> **Tapa todos los nombres propios de la skill. Si el procedimiento sigue
> teniendo sentido y valor, hay un patrón dentro.**

Se promueve el procedimiento; queda en `project/` un adaptador corto con rutas,
credenciales y nombres. Con dos guardas:

- **Regla de las dos ocurrencias.** Se promueve cuando dos proyectos lo
  necesitan de verdad, no cuando "podría servir algún día". Excepción admisible:
  valor alto demostrado y acoplamiento casi nulo.
- **Existe el camino inverso.** Si una skill del kernel empieza a acumular
  condicionales por proyecto, no era un patrón: se degrada a `project/`.

`/skill-audit` aplica este test de forma periódica y al crear una skill nueva.

### Catálogo del kernel

| Skill | Para qué |
| ----- | -------- |
| `crux-init`, `crux-doctor`, `add-repo-to-docs` | Gestión del estándar |
| `promote-to-docs`, `adr`, `end-session` | Que el conocimiento sobreviva |
| `repo-map` | Orientarse en un repo desconocido o dormido |
| `workspace`, `ship` | El ciclo de trabajo diario |
| `write-tests`, `root-cause`, `eval-fixtures` | Calidad y depuración |
| `visual-test`, `visual-diff`, `render-loop`, `device-loop` | Verificación con los ojos |
| `auth-bypass-local`, `oauth-reauthorize`, `deploy-fallback` | Operación |
| `skill-creator`, `skill-audit` | El propio framework |

### El ciclo de desarrollo

Tres skills sostienen el trabajo del día a día, y se usan en este orden:

1. **`/workspace`** — antes de empezar, si va a haber trabajo en paralelo sobre
   el mismo repo. Aísla ficheros **y runtime**: sin lo segundo, dos tareas
   simultáneas se corrompen los datos en silencio.
2. **`/ship`** — antes de commitear. Cadena de puertas donde cualquiera aborta:
   sanidad, diff, correctitud, simplificación, regresión, validación real solo
   si el cambio toca superficie observable, deriva de la documentación, commit.
3. **`/end-session`** — antes de cerrar. Lo que deba sobrevivir a la sesión se
   escribe en git, se verifica la conformidad y se commitea.

---

## Comandos

| Comando | Skill | Qué hace |
| ------- | ----- | -------- |
| `crux init <project>` | `/crux-init` | Crea el docs repo desde las plantillas |
| `crux adopt` | `/crux-adopt` | Registra un docs repo que ya existe |
| `crux add-repo <repo>` | `/add-repo-to-docs` | Registra un repo nuevo en el proyecto |
| `crux link` | — | Genera y verifica los punteros de los repos de código |
| `crux workspace` | `/workspace` | Espacios aislados para trabajar en paralelo |
| `crux doctor` | `/crux-doctor` | Verifica conformidad con el estándar |
| `crux upgrade` | `/crux-upgrade` | Re-materializa el kernel a la versión actual |
| `crux doctor --machine` | — | Verifica el entorno de la máquina |
| `crux hooks install` | — | Engancha el estándar al cierre de sesión y al commit |
| `crux usage` | — | Mide qué skills se usan realmente |

---

## Anti-patterns

- **Inventar carpetas temáticas en la raíz.** Si es de un repo, va en
  `repos/<repo>/`. Si es transversal universal, en las tres carpetas
  canónicas. Si es del dominio, bajo `topics/`.
- **Guardar información de proyecto en auto-memory local.** Se pierde al
  cambiar de máquina.
- **Confiar en los commit bodies como sustituto de la documentación.** Los
  commits explican cambios; la documentación explica estado estable.
- **Múltiples `CLAUDE.md` largos.** Solo el del docs repo tiene contenido; los
  de los repos de código son punteros generados.
- **Copiar el kernel a mano en un proyecto.** Para eso está `crux upgrade`. La
  copia manual es el origen del drift.
- **Asumir que sin agente la disciplina aguanta.** Por eso existe
  `crux doctor`: el estándar se verifica, no se confía.

---

## Versionado

`VERSION` sigue semver:

- **patch** — correcciones de redacción, fixes de scripts sin cambio de contrato
- **minor** — nuevas plantillas, skills o comprobaciones; los proyectos siguen válidos
- **major** — cambia la estructura obligatoria o el formato de `crux.json`

Cuando el estándar evoluciona se cambia **aquí primero**, y los proyectos se
alinean con `crux upgrade` cuando toque. No se permite que un proyecto invente
su propia variante.
