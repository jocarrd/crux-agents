# El estándar

Este documento define cómo se organiza la documentación y el trabajo con
agentes en cualquier proyecto. Vive en `crux` — el kernel — y es la **única**
fuente canónica. Los proyectos no inventan variantes: consumen esta.

Para bootstrap de un proyecto nuevo: `/crux-init <project>`.

---

## TLDR — lo que tiene que saber un agente

1. **Tres capas**: kernel (`crux`), proyecto (`<project>-docs`), repo (punteros generados).
2. **Layout**: repos hermanos dentro de una carpeta por proyecto, y uno de ellos es `<project>-docs/`. La raíz que contiene los proyectos la fija cada máquina, no el estándar.
3. **Doc específica de un repo** vive en `<project>-docs/repos/<repo>/`. Nunca en `<repo>/docs/`.
4. **Doc transversal** vive en `<project>-docs/{architecture,conventions,operations}/` (universales) o `<project>-docs/topics/<tema>/` (del dominio del proyecto).
5. **`crux.json`** en cada docs repo declara versión, perfil y repos. Nada se hardcodea en scripts.
6. **Punteros de cada repo de código**: `AGENTS.md` (canónico) y `CLAUDE.md` (symlink o `@-import`). Cortos, generados, no se editan a mano.
7. **Sync discipline**: al cambiar código que afecta a una doc, se actualiza la doc en el mismo turno.
8. **Auto-memory**: `project` y `reference` van a git (`<project>-docs/`). Solo `user` y `feedback` se quedan locales.
9. **ADRs cross-repo** → `decisions/index.md`. **Single-repo** → `repos/<repo>/decisions.md`. Siete estados y ninguno más.
10. **Runbooks**: lo de `operations/` se ejecuta, no se lee. Síntoma, confirmar, actuar, verificar, escalar — y se escribe en caliente.
11. **Markdown links** solo a ficheros dentro del propio docs repo. Referencias a código de repos hermanos, en backticks sin enlazar.
12. **Skills**: las transversales viven en el kernel; las del proyecto en `<project>-docs/.claude/skills/project/`. La frontera la decide el test de la sección "Promoción de skills".
13. **Cierre de sesión**: `/end-session` promueve lo que deba sobrevivir, verifica drift y commitea.

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
  "language": "es",
  "branch": "main",
  "repos": ["Acme", "acme-engine", "acme-cms"],
  "sections": ["architecture", "conventions", "operations", "topics"]
}
```

| Campo | Significado |
| ----- | ----------- |
| `crux` | Versión del kernel con la que se materializó este proyecto |
| `language` | Idioma de la documentación y de las descripciones de skills |
| `branch` | Rama principal del proyecto. `main` por defecto; se declara porque el hook que la protege y los espacios de trabajo la leen de aquí |
| `remote` | De dónde se clonan los repos del proyecto |
| `project` | Nombre del proyecto, igual que la carpeta padre |
| `profile` | Perfil aplicado (ver siguiente sección) |
| `repos` | Repos de código del proyecto, hermanos del docs repo |
| `sections` | Carpetas opcionales activas |
| `quality` | Cómo se ejecutan los tests aquí (opcional, ver abajo) |
| `conventions` | Reglas de estilo comprobables mecánicamente (opcional, ver abajo) |

Ningún script del kernel hardcodea nombres de proyecto ni listas de repos: todo
sale de aquí. Si el fichero falta, el proyecto no está adoptado y `crux doctor`
lo reporta como el primer error.

### El remoto

El kernel no sabe de proveedores. Cada proyecto declara cómo se componen las
URLs de sus repos:

```json
"remote": {
  "url": "git@github.com:jocarrd/{repo}.git",
  "repos": {
    "codigo-del-cliente": "https://otro-host.com/su-org/codigo-del-cliente.git"
  }
}
```

`url` es una **plantilla** con `{repo}`. Es el formato primario porque es el
único que cubre remotos que no siguen la forma `owner/repo`. Para el caso
común hay un atajo equivalente: `host`, `owner` y `protocol`.

`repos` permite un **override por repo**, y no es un caso raro: un proyecto
puede tener la documentación en tu remoto y el código en el de otra persona.
Es exactamente lo que ocurre con el perfil `client-repo`.

`visibility` declara si el docs repo debe ser privado o público. Importa
porque **la visibilidad solo la puede aplicar el kernel donde hay API para
crearlo**: en el resto de proveedores el repo lo crea una persona, y un docs
repo público con documentación interna dentro es un incidente, no un descuido
de configuración. Por eso se declara y `crux doctor` la comprueba donde puede.

`crux adopt` lo deduce del `origin` de lo que ya esté clonado, así que no hay
que escribirlo a mano. `crux doctor` avisa si lo declarado deja de coincidir
con la realidad, que es la deriva que hace fallar el clonado en la máquina
siguiente.

### Los tests

```json
"quality": {
  "tests": "pnpm test",
  "testsFiltered": "pnpm test {filtro}"
}
```

Es opcional y lo consume la puerta de calidad. `testsFiltered` recibe en
`{filtro}` los ficheros o módulos que toca el diff, y sirve para que **la
primera puerta corra solo lo afectado**: ahí únicamente se pregunta si el rojo
ya venía de antes, y la suite entera es la puerta de regresión. Sin este campo
la puerta sigue funcionando, pero dice por dónde filtrar en vez del comando.

### Las convenciones comprobables

```json
"conventions": {
  "checks": [
    { "name": "tipos dentro de un fichero de constantes",
      "files": "*.consts.ts",
      "forbid": "^\\+\\s*(export )?(interface|type) [A-Z]" }
  ]
}
```

Es opcional y lo consume la puerta de convenciones. Cada entrada dice que en
los ficheros que casan con `files`, ninguna línea añadida debe casar con
`forbid`.

Se declara aquí y no en el kernel porque **cada proyecto escribe distinto**, y
un kernel que impusiera el estilo de uno haría ruido en todos los demás. Las
señales que valen en cualquier lenguaje —un literal repetido, un catálogo que
ya existe— van en la puerta y no se declaran.

Una regla declarada no se aplica si el repo no tiene ni un fichero que case con
su `files`: la convención está escrita pero ese repo todavía no la usa, y no
hay nada que exigir. Y un `crux.json` que no se puede leer **detiene la
puerta**, no la deja en cero reglas.

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
  explícitamente. Si el repo del cliente **ya traía** su propio `AGENTS.md`
  versionado, no es una intrusión: se respeta y se sigue. `doctor` distingue el
  fichero del cliente del puntero nuestro, que lleva el bloque gestionado.
- **Se registran mediciones, no diagnósticos.** No se declara algo como bug ni
  se concluye qué está mal sin validación del cliente.
- **Toda observación lleva evidencia reproducible**: fichero y línea, comando o
  consulta que la demuestra. Sin evidencia no se escribe.
- **Distinguir lo medido de lo heredado.** La documentación previa describe la
  intención del momento en que se escribió, no el estado actual: verificar
  antes de citarla.
- **Las propuestas no enseñan nuestro andamiaje.** Ni el tooling, ni los
  nombres de rama, ni los procesos internos. Ver §8.

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

Y va **en git**, con remoto: es la condición que hace que el conocimiento
sobreviva al cambio de máquina, que es para lo que existe todo esto. `doctor`
lo comprueba, y sin repo tampoco puede verificar que el remoto declarado
coincida con el real.

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

### Cuando el proyecto crece: de un repo a varios

Un proyecto suele empezar con un solo repo, y entonces casi toda su
documentación es de ese repo: va en `repos/<repo>/`, y sus decisiones en
`repos/<repo>/decisions.md`. Las carpetas transversales se quedan vacías o casi,
porque todavía no hay nada que cruce repos. Es correcto: no se preparan "por si
acaso".

Cuando entra el segundo repo, lo transversal deja de ser hipotético y se mueve
lo que ya vale para varios:

- Un overview del sistema, una convención compartida o un despliegue común sube
  de `repos/<repo>/` a la carpeta transversal que le toque.
- Una decisión que ahora afecta a más de un repo pasa de
  `repos/<repo>/decisions.md` a `decisions/index.md`, marcando la vieja como
  movida. Las que siguen siendo de un repo se quedan donde están.

Mover cuatro documentos el día que llega el segundo repo es más barato que
mantener carpetas vacías que sugieren un reparto que aún no existe.

---

## Convenciones duras

No se negocian: son las que hacen que el sistema escale a varios proyectos sin
romperse.

### 1. Layout en filesystem

- La carpeta del proyecto se llama como el proyecto, en kebab-case.
- Los repos son hermanos directos dentro de ella.
- El docs repo se llama `<project>-docs` y es uno de esos hermanos.

Lo obligatorio es **la relación entre las carpetas**, no dónde estén: es lo que
hace que la referencia relativa funcione siempre. Cada repo apunta a
`../<project>-docs/` y el agente lo resuelve sin configuración.

**La raíz que contiene los proyectos la fija cada máquina**, y por defecto es
el directorio donde está clonado el kernel: si `crux` vive en `/opt/dev/crux`,
los proyectos van en `/opt/dev`. Se puede cambiar al instalar
(`install.sh --projects-dir`), y queda escrita en `~/.crux/config` para que la
lean también los hooks y los comandos que recorren todos los proyectos.

El kernel es la excepción al layout: `crux` no es un proyecto y no tiene
hermanos, vive directamente en la raíz.

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
- Mientras haya menos de 30 cross-repo, todos en un solo fichero. Al pasar de
  ahí, el registro abre con una tabla de contenidos —número, título, estado—
  antes de partirlo en ficheros: partir obliga a reescribir todas las
  referencias que lo citan desde otras docs, y la tabla resuelve el problema
  real, que es encontrar una decisión sin leerlas todas.
- Plantilla única para ambos niveles, definida en `decisions/README.md`.
- Numeración local a cada ledger. Para citar entre ledgers, prefijo del path:
  `decisions/ADR-013` o `repos/demo-co/ADR-007`.
- **Siete estados y ninguno más**: `Open`, `Proposed`, `Accepted`, `Inherited`,
  `Superseded by <ref>`, `Amended by <ref>`, `Deprecated`. El campo lleva el
  estado y sus referencias, nada más; el porqué del cambio vive en el ADR que
  lo provoca. La lista salió de lo que dos proyectos ya escribían a mano.
- Una decisión aceptada a sabiendas de que hay que retirarla lleva `Sunset`
  con la condición de retirada. Es un campo, no un estado: está aceptada **y**
  caduca, y como estado habría que renunciar a una de las dos.
- Al superseder o enmendar, se marca el viejo. No se borra.

### 5. Runbooks

Lo que vive en `operations/` no es prosa explicativa: es lo que alguien
ejecuta con el sistema caído. Tiene forma propia y obligatoria.

Un **runbook** resuelve un problema concreto y conocido. Un **playbook** dice
cómo se responde en general —qué se mira primero, cuándo se declara incidente,
a quién se avisa— y en un proyecto pequeño suele ser un índice por síntoma que
apunta a los runbooks.

Las cinco partes de un runbook, en este orden:

| Parte | Qué contiene |
| ----- | ------------ |
| **Síntoma** | Cómo se ve desde fuera, con las palabras de quien lo sufre |
| **Confirmar** | Cómo distinguirlo de lo que se le parece |
| **Actuar** | Los comandos, en orden |
| **Verificar** | Cómo se sabe que se arregló |
| **Escalar** | Cuándo dejar de intentarlo y qué hacer entonces |

**Cada paso es un comando, no una historia.** El síntoma se escribe como lo
diría quien lo reporta, porque es lo que se teclea al buscarlo; el porqué va a
`architecture/` y el runbook enlaza si hace falta. Un runbook sin `Verificar`
deja declarar resuelto lo que no lo está, y sin `Escalar` convierte cada
incidente en una carrera sin línea de meta.

**Lleva la fecha en que se comprobó por última vez.** Un runbook envejece sin
avisar: cambian los puertos, las rutas del servidor, los límites de un tercero.
La marca no dice que siga siendo cierto, dice cuándo se supo que lo era, y eso
basta para decidir si te fías o lo verificas antes. `crux doctor` avisa de los
que pasan de seis meses.

**Se escribe en caliente**, justo después de resolver, que es el único momento
en que se conoce el detalle. Escrito en frío sale una explicación, no un
procedimiento. Para eso está `/runbook`.

Un procedimiento que se repite en varios proyectos no es un runbook: es una
skill. La frontera es la misma de siempre — si al tapar los nombres propios
sigue teniendo sentido, hay un patrón.

### 6. Auto-memory del agente

Cuatro tipos: `user`, `feedback`, `project`, `reference`.

- `user` y `feedback` se quedan **locales** — son sobre la persona, no sobre el proyecto.
- `project` y `reference` se **promueven a git** en el mismo turno:
  - Operativa y gotchas → `operations/`
  - Punteros a recursos externos → `operations/` o el README que corresponda
  - Estado del proyecto → `repos/<repo>/notes.md`

Esto **se verifica**: `crux memory` lista las que siguen solo en local, y el
hook que instala `crux hooks install` lo recuerda al cerrar sesión. La regla
llevaba escrita desde el primer día y dependía de que alguien invocase el
ritual de cierre, que se invocaba en 2 de 46 sesiones; mientras tanto había
análisis de proyecto que solo existía en una máquina. Una regla que no se
comprueba es una recomendación.

Lo que el kernel no hace es decidir por ti: dice qué falta y en qué docs repo
va. Dónde encaja dentro de él es una decisión, y las decisiones no las toma un
hook.

### 7. Sincronización código ↔ doc

Cuando se modifica código que afecta a una doc, **se actualiza la doc en el
mismo turno**. No después, no en otro commit. Si el cambio no afecta a ninguna
doc (rename interno, test, refactor invisible), no se toca nada.

La proximidad física entre código y doc ya no la da el filesystem: la da esta
disciplina.

#### Lo que se pierde no suele ser un fichero

La regla de arriba solo cubre lo que deja rastro en el diff, y ese no es el
caso que hace daño. El caso que hace daño es una sesión que **mide algo,
descubre un riesgo o resuelve una pregunta abierta**, commitea el código
limpio, y se cierra sin que nada de eso llegue al docs repo. No hay fichero que
delate la pérdida, así que ninguna comprobación basada en el diff la ve.

Antes de cerrar una sesión hay que **responder explícitamente** qué se queda:

| Lo que pasó en la sesión | Dónde vive |
| ------------------------ | ---------- |
| Decisión con alternativas descartadas | `decisions/` (ADR) |
| Algo medido que costaría repetir | `repos/<repo>/` u `operations/` |
| Gotcha de infraestructura o despliegue | `operations/` |
| Riesgo nuevo | `operations/open-risks.md` |
| Pregunta abierta que se ha resuelto | donde estaba la pregunta |
| Estado de un repo que ha cambiado | `repos/<repo>/notes.md` |

**"No hay nada que promocionar" es una respuesta válida**, pero tiene que ser
una respuesta. La diferencia entre decidir que no hace falta y no acordarse es
justo lo que este apartado existe para eliminar.

#### Cómo se sostiene

No con buena voluntad. Con tres piezas, en orden de dureza:

1. **La puerta de cierre** (`adapters/<agente>/hooks/doc-sync.sh`) — al terminar
   la sesión, si el proyecto se ha movido, **bloquea el cierre una vez** y pide
   la respuesta. Bloquea como mucho una vez por sesión: un hook que bloquea
   siempre se acaba desinstalando, y entonces no vigila nada.
2. **`crux doctor`** — mide la deriva entre el último commit de cada repo de
   código y el último de documentación. Es la parte auditable: permite ver a
   posteriori si la puerta se estuvo saltando.
3. **`/promote-to-docs` y `/end-session`** — el procedimiento para ejecutarlo.

La medida de doctor no dice **qué** falta documentar; eso no se sabe desde git.
Dice que el código lleva moviéndose sin que la documentación se mueva, que es
la única señal objetiva disponible. El juicio lo sigue poniendo quien cierra:
la puerta solo garantiza que se le pregunte.

### 8. Commits y propuestas de cambio

- Conventional commits (`feat:`, `fix:`, `chore:`, `docs:`, `refactor:`…)
- Subject en minúscula e imperativo
- Body de 100 caracteres por línea como máximo
- Sin `Co-Authored-By`
- Sin emojis, salvo que la voz del fichero lo justifique

**Nada de lo que se publica lleva la firma de la herramienta que lo escribió.**
Ni el `Co-Authored-By` en el commit, ni una línea de "generado con" al pie de la
descripción de una propuesta de cambio, ni el emoji que suele acompañarla. El
autor es quien firma el commit; con qué herramienta lo hizo no es información
del repositorio.

Aplica al cuerpo de la propuesta igual que al commit: se describe el cambio, lo
que se comprobó y lo que queda, y ahí se acaba.

#### Qué lleva la descripción de una propuesta

**Qué cambia, qué se añade y por qué.** Luego, lo que se comprobó y lo que queda
pendiente. Ahí se acaba.

No es una bitácora. No cuenta el camino que recorrió quien la escribió, ni las
vueltas que dio, ni qué herramienta ejecutó cada paso. Quien la revisa necesita
juzgar el cambio, no reconstruir la sesión.

**Y el listón cambia según de quién sea el repo:**

| | Repo propio | Repo de cliente |
| --- | --- | --- |
| Comandos y scripts del propio repo | Se nombran | Se nombran — son suyos |
| Nuestro tooling: `crux`, sus comandos, sus skills, sus marcas | Se nombra | **No aparece** |
| Nuestros nombres de rama, espacios de trabajo o procesos internos | Se nombran | **No aparecen** |

En el repo de un cliente, quien lee no conoce cómo trabajamos por dentro ni
tiene por qué. Nombrar ahí nuestro andamiaje no añade rigor: añade ruido y
enseña una maquinaria que no es del proyecto. Un script que está en el
`package.json` del cliente es suyo y se cita con naturalidad; lo nuestro se
queda fuera.

La distinción no es de tono, es de propiedad: el repo declara su perfil en
`crux.json`, y `client-repo` es el que la activa.

#### La puerta se gana, no se declara

`crux ship run -- <comando>` ejecuta la comprobación y anota su código de salida;
`crux ship seal` cierra el recibo contra el sha de HEAD. `workspace finish` lo
lee y **se niega a proponer** si no hay recibo, si no registra ni un comando, si
alguno está en rojo o si el sha no es el de HEAD.

Antes era un sha suelto que escribía el propio agente después de afirmar que
había verificado. Eso no prueba que verificara: prueba que escribió un sha.

**El atajo existe y es legítimo cuando lo pide una persona**: `finish
--sin-puerta`, y lo dice en voz alta. Lo que no puede pasar es que un agente lo
tome por su cuenta. Esa es la línea en todo el estándar —`--no-verify`,
`--force`, `--admin`, `--sin-puerta`—: son para obedecer a quien decide, no para
que el agente se ahorre un paso.

---

## Idioma

El estándar no impone un idioma global: impone **coherencia dentro de un
proyecto**, declarada en `crux.json` con `"language"`.

| Qué | Idioma |
| --- | ------ |
| Descripciones de skills | El del proyecto |
| Cuerpo de skills y documentación | El del proyecto |
| Nombres de skills, comandos, ficheros, ramas y commits | Inglés |
| Términos técnicos | Sin traducir: `worktree`, `commit`, `hook`, `deploy` |

Lo de los commits **se verifica**: `crux hooks install` pone un `commit-msg`
que rechaza los mensajes en español. Esta regla llevaba escrita desde el primer
día y el historial del kernel estaba entero en español — una regla que nadie
comprueba es una recomendación.

Es una red para el descuido, no un detector de idioma: exige dos palabras
funcionales españolas, así que un título casi sin prosa se le escapa y un
topónimo como "Los Angeles" no lo dispara. `--no-verify` lo salta cuando de verdad
haga falta.

**Las descripciones son lo que decide la activación de una skill**, y deben
contener las palabras con las que aparece el problema. Si el trabajo se pide en
un idioma y la descripción está en otro, la skill existe pero se activa peor
justo cuando hace falta. `crux doctor` avisa de la mezcla.

Los nombres van en inglés porque son identificadores, no prosa: `write-tests`,
`ship`, `workspace`. Y los términos técnicos no se traducen porque traducirlos
genera ambigüedad, no claridad.

**Un proyecto cuyo código o cuyos interlocutores sean de otro idioma lo declara
y se escribe entero en ese idioma.** Es una propiedad del proyecto, no una
decisión que se vuelve a tomar en cada fichero.

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
| `promote-to-docs`, `adr`, `runbook`, `explain-plan`, `end-session` | Decidir, operar y que el conocimiento sobreviva |
| `repo-map` | Orientarse en un repo desconocido o dormido |
| `read-document` | Leer un documento que el agente no puede abrir |
| `flow` | **El ciclo completo y su orden** — la entrada por defecto |
| `workspace`, `ship`, `review-pr` | Las piezas del ciclo: aislar, verificar y revisar |
| `write-tests`, `e2e`, `root-cause`, `eval-fixtures` | Calidad y depuración |
| `bug-hunt` | Buscar los fallos que nadie ha reportado |
| `code-health` | Salud estructural del conjunto y su tendencia |
| `visual-test`, `visual-diff`, `render-loop`, `device-loop` | Verificación con los ojos |
| `css-to-components` | Mover estilos a los componentes sin cambiar el diseño |
| `auth-bypass-local`, `oauth-reauthorize`, `deploy-fallback`, `share-local`, `drive-browser` | Operación |
| `carry-env` | Llevarte a otra máquina lo que los repos no llevan |
| `skill-creator`, `skill-audit` | El propio framework |

### El ciclo de desarrollo

Cuatro skills sostienen el trabajo del día a día, y se usan en este orden:

**El orden lo declara `/flow`**, que es lo que un agente lee primero. Resumido:

1. **`/workspace`** — antes de empezar, si va a haber trabajo en paralelo sobre
   el mismo repo. Aísla ficheros **y runtime**: sin lo segundo, dos tareas
   simultáneas se corrompen los datos en silencio.
2. **`/ship`** — antes de commitear. Cadena de puertas donde cualquiera aborta:
   sanidad, diff, correctitud, simplificación, regresión, validación real solo
   si el cambio toca superficie observable, deriva de la documentación, commit.
3. **`/review-pr`** — con la propuesta ya abierta, desde un contexto
   independiente del que escribió el cambio. `/ship` pregunta si está listo lo
   que hiciste; esto, si es correcto y completo lo que se propone. Quien acaba
   de defender cada decisión no está en posición de refutarlas.
4. **`/end-session`** — antes de cerrar. Lo que deba sobrevivir a la sesión se
   escribe en git, se verifica la conformidad y se commitea.

---

## Comandos

| Comando | Skill | Qué hace |
| ------- | ----- | -------- |
| `crux init <project>` | `/crux-init` | Crea el docs repo desde las plantillas |
| `crux clone <project>` | — | Trae un proyecto entero a una máquina nueva |
| `crux bootstrap` | — | Deja una máquina nueva lista: verifica, descubre los proyectos y los trae |
| `crux adopt` | — | Registra un docs repo que ya existe |
| `crux add-repo <repo>` | `/add-repo-to-docs` | Registra un repo nuevo en el proyecto |
| `crux review` | `/review-pr` | Reúne el material de la revisión de una propuesta |
| `crux merge <n>` | — | Mergea una propuesta diciendo antes cuál y de qué repo |
| `crux link` | — | Genera y verifica los punteros de los repos de código |
| `crux workspace` | `/workspace` | Espacios aislados para trabajar en paralelo |
| `crux ship` | `/ship` | La puerta de calidad, con recibo de lo ejecutado |
| `crux doctor` | `/crux-doctor` | Verifica conformidad con el estándar |
| `crux upgrade` | — | Re-materializa el kernel a la versión actual |
| `crux release <ver>` | — | Publica una versión del kernel |
| `crux doctor --machine` | — | Verifica el entorno de la máquina |
| `crux hooks install` | — | Engancha el estándar al ciclo, al cierre de sesión y al commit |
| `crux usage` | — | Mide qué skills se usan realmente |
| `crux memory [--check]` | — | Memorias del agente que deberían estar en git |
| `crux status` | `--check` | Proyectos, espacios y trabajo sin publicar |

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
