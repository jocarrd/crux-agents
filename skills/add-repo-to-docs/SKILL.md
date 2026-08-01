---
name: add-repo-to-docs
description: Añadir un repo nuevo a un proyecto ya adoptado bajo el estándar. Crea su carpeta de documentación, lo declara en crux.json, lo registra en la tabla de repos y genera sus punteros de contexto. Usa cuando crees o clones un repo nuevo dentro de un proyecto que ya tiene su docs repo.
---

# add-repo-to-docs

Registra un repo nuevo en el docs repo de un proyecto que ya sigue el estándar.

## Cuándo usar

- Acabas de crear o clonar un repo dentro de `~/Proyectos/<project>/`.
- Quieres que el proyecto lo reconozca: carpeta de documentación, entrada en
  el contrato, fila en el índice y punteros de contexto.

## Precondiciones

- El proyecto ya tiene su `<project>-docs/` con `crux.json`. Si no,
  `crux adopt` o `/crux-init` primero.
- El repo vive como hermano del docs repo. La convención de layout es
  obligatoria: sin ella, las referencias relativas dejan de resolver.

## Flujo

### 1. Recoger los datos

Pregunta al usuario, si no los tienes:

- **Nombre del repo**, exactamente igual que en el remoto.
- **Qué hace**, en una línea. Va al índice y a la cabecera de su
  documentación, así que merece la pena que sea precisa y no genérica.

### 2. Ejecutar

```bash
crux add-repo <repo> --description "qué hace, en una línea"
```

Esto, en un solo paso:

- crea `repos/<repo>/README.md` desde la plantilla del kernel;
- declara el repo en `crux.json`;
- añade su fila a la tabla de `repos/README.md`;
- genera `AGENTS.md` y `CLAUDE.md` en el repo de código, salvo que el perfil
  del proyecto lo prohíba;
- deja el resto de punteros verificados.

### 3. Verificar

```bash
crux doctor
```

Debe salir conforme. Si avisa de que el repo no está en disco, es que se
declaró antes de clonarlo: no es un error, pero los punteros no se han creado
todavía y hay que volver a pasar `crux link` cuando esté.

### 4. Commitear

```
docs(repos): add <repo>
```

Pregunta antes de pushear.

## Después

La carpeta nace con solo un README. Se llena a demanda, no de golpe: cuando
aparezca una decisión que afecta solo a ese repo, `decisions.md`; cuando haya
estado o bloqueos que recordar, `notes.md`; cuando haya un contrato de API o
un sistema visual que explicar, su fichero temático.

## Errores comunes

- **El proyecto no está adoptado todavía.** Deriva a `crux adopt`.
- **El repo está fuera de la carpeta del proyecto.** Muévelo antes; la
  convención de hermanos no es opcional.
- **Ya existe la carpeta con otro contenido.** El comando aborta en vez de
  pisarla. Decide si fusionar a mano o renombrar.

## Relacionado

- `/crux-init` — crear el docs repo de un proyecto nuevo
- `/crux-doctor` — verificar conformidad
- `/promote-to-docs` — mover información suelta a su sitio
