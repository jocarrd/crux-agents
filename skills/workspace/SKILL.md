---
name: workspace
description: Crear espacios de trabajo aislados para trabajar en varias tareas del mismo repo a la vez, repartiendo no solo los ficheros sino también el runtime: worktree propio, rango de puertos reservado, base de datos separada y fichero de entorno derivado. Usa cuando vayas a lanzar varias tareas en paralelo sobre un repo, cuando necesites tocar dos ramas a la vez sin hacer stash, o cuando dos procesos se estén peleando por el mismo puerto.
---

# workspace

Un worktree aísla los ficheros, pero no el runtime: dos tareas en paralelo se
siguen peleando por el puerto, la base de datos y el fichero de entorno, y el
fallo aparece como datos corrompidos en silencio. Esta skill reparte las dos
cosas. El porqué de cada decisión: `<directorio-de-esta-skill>/references/por-que.md`.

## Uso

```bash
crux workspace new <nombre> [--repo <dir>] [--branch fix/algo] [--task <tarea>] [--goal "qué y por qué"]
crux workspace list
crux workspace finish <nombre>          # sube la rama y abre la propuesta
crux workspace merge <nombre> [--yes]   # sin --yes solo enseña el estado
crux workspace rm <nombre>
crux workspace adopt <ruta>             # registra un worktree creado a mano
```

`new` crea el worktree en `<repo>-ws-<nombre>` (al lado del repo, para que
resuelvan las rutas relativas al docs repo), en una rama nueva, reserva un slot,
escribe el fichero de entorno y registra la tarea.

**La rama se publica:** por defecto es `ws/<nombre>`; en un repo de cliente,
fija el nombre con `--branch` (el comando avisa si el perfil es
`client-repo`). Si el perfil prohíbe escribir fuera del docs repo, `new` se
niega salvo con `--force`, solo si el cliente lo autoriza.

## Configurar el reparto

En `crux.json`, sección `workspace`:

```json
"workspace": {
  "portBase": 3000,
  "portsPerSlot": 10,
  "envFile": ".env.local",
  "env": {
    "PORT": "{{PORT0}}",
    "ENGINE_PORT": "{{PORT1}}",
    "DATABASE_URL": "postgres://localhost/app_ws{{SLOT}}",
    "REDIS_URL": "redis://localhost:6379/{{SLOT}}"
  }
}
```

Sustituciones: `{{SLOT}}`, `{{PORT0}}`…`{{PORTn}}`, `{{NAME}}` y `{{BRANCH}}`.
Sin esta sección solo se reservan puertos; rellénala.

Qué aislar, en orden de daño: **puertos**, **base de datos** (una base o esquema
por slot; en Redis, un número de base), **fichero de entorno**, **volúmenes y
cachés con estado**. Los recursos externos compartidos (webhooks, colas,
buckets) no se aíslan: no lances en paralelo tareas que los toquen.

## Antes de lanzar tareas en paralelo

- Reparte por superficie, no por fichero.
- Una tarea con migraciones va sola: el esquema se comparte en cuanto las ramas
  se juntan.
- Nombra los espacios por la tarea (`fix-login`), no por número.

## La tarea del espacio

El registro vive en `~/.crux/tasks/<proyecto>/<tarea>.md`. Si la tarea toca
otro repo, se abre allí otro espacio con el mismo `--task`.

```bash
crux task                          # estado, pasos y siguiente paso
crux task add "paso" "otro paso"   # devuelve T1, T2…
crux task done T1 "lo que lo prueba"
crux task next "lo siguiente"
crux task note "desviación del plan"
crux task note "qué se decidió" --why "por qué" --where "dónde vive" --learned "qué se aprendió"
crux task plan <fichero>           # el plan aprobado
```

Se anota **mientras se trabaja**, en el idioma de los commits del repo: de ahí
sale la descripción de la propuesta. Las notas con `--why` pasan solas a
`repos/<repo>/notes.md` del docs repo al archivar la tarea.

## Cerrar el ciclo

- `finish` se niega si queda algo sin commitear o si el commit no ha pasado la
  puerta de calidad. El `pre-push` impide subir directo a la rama principal de
  un repo de código.
- `merge` mira CI, conflictos y cambios pedidos en la revisión, y **nunca
  fusiona sin `--yes`**. Si el repo no tiene CI, lo dice: no es lo mismo que
  estar verificado.
- **Un espacio se cierra con `crux workspace rm`**, nunca con `git worktree
  remove` ni `rm -rf` (un hook lo para). `rm` se niega si hay cambios sin
  commitear, libera el worktree y el slot, y deja la rama. Si era el último
  espacio de una tarea fusionada, la archiva. `merge --yes` ya cierra el
  espacio al fusionar.

## Relacionado

- `/ship` — la puerta de calidad antes de commitear
- `/flow` — el ciclo completo
