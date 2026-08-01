---
name: promote-to-docs
description: Promover información que estaba en la memoria local del agente, en un commit message o solo en la conversación al sitio correcto del docs repo (decisions/, operations/, conventions/ o repos/<repo>/notes.md) y commitearla. Usa cuando estés a punto de guardar una memoria de tipo project o reference, o cuando una conversación haya generado conocimiento operativo o decisional que no va a quedar en el código.
---

# promote-to-docs

Mueve información del ámbito local y efímero al ámbito durable: git.

## Cuándo usar

- Estás a punto de guardar una memoria de tipo `project` o `reference`. El
  estándar dice que esas van a git, no a local.
- Una conversación ha decidido algo, descubierto un gotcha o fijado una
  convención que ahora mismo no está en ningún sitio duradero.

## Cuándo no usar

- Para memorias de tipo `user` o `feedback`: esas se quedan locales, son sobre
  la persona y no sobre el proyecto.
- Para detalles de implementación que el propio código ya explica.
- Para todo lo que se te ocurra. Promover es selectivo: si en seis meses no va
  a ayudar a nadie, no merece la pena.

## Flujo

### 1. Identificar la pieza

- Qué se va a documentar, en una o dos líneas.
- A qué proyecto pertenece.
- De qué tipo es: decisión cross-repo, decisión single-repo, operativa,
  convención o nota de estado.

### 2. Localizar el docs repo

`~/Proyectos/<project>/<project>-docs/`. Si no existe, el proyecto no está
bajo el estándar todavía: usa `/crux-init` o `crux adopt` antes.

### 3. Decidir el destino

| Tipo | Destino |
| ---- | ------- |
| Decisión cross-repo | `decisions/index.md`, como ADR nuevo |
| Decisión single-repo | `repos/<repo>/decisions.md` |
| Operativa, gotcha, infraestructura | `operations/<tema>.md` |
| Convención de código transversal | `conventions/<tema>.md` |
| Estado o contexto de un repo | `repos/<repo>/notes.md` |

Ante la duda entre cross y single-repo, empieza por single: promocionarlo
después está previsto en el formato; separarlo, no.

### 4. Escribir

- **ADRs**: plantilla canónica de `decisions/README.md`, con el siguiente
  número correlativo del registro donde va.
- **operations/ y conventions/**: si ya hay un fichero del mismo tema, añade
  una sección; no crees uno nuevo. Estas carpetas se vuelven inútiles cuando
  cada gotcha tiene su propio fichero.
- **notes.md**: entradas con fecha, la más reciente arriba.

Fechas en absoluto (`2026-08-01`), nunca en relativo: "la semana pasada" no
significa nada cuando alguien lo lea en marzo.

### 5. Limpiar el origen

Si venía de la memoria local del agente, bórrala junto con su línea en el
índice. Si no, queda duplicada en dos sitios que divergirán.

### 6. Commitear

Un mensaje que diga dónde fue y qué es:

```
docs(decisions): add ADR-NNN <título>
docs(operations): document <título>
docs(conventions): add <título>
docs(repos/<repo>): note on <título>
```

Preguntar antes de pushear.

## Cómo distinguir el tipo

| Pista | Tipo probable |
| ----- | ------------- |
| "Por qué decidimos X", afecta a un repo | decisión single-repo |
| "Por qué decidimos X", afecta a varios | decisión cross-repo |
| "Cuando pase X, hacer Y" en infra o datos externos | operativa |
| "Regla aplicable en todos los repos" | convención |
| "X está bloqueado porque Y" | nota de estado |

## Anti-patterns

- **Promover por promover.** Si el commit ya lo explica bien, no hace falta.
- **Crear fichero nuevo habiendo uno del mismo tema.**
- **Olvidar el borrado del origen local.**

## Relacionado

- `/end-session` — el ritual completo de cierre, que incluye esto
- `/add-repo-to-docs` — registrar un repo nuevo en el proyecto
