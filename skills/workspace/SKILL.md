---
name: workspace
description: Crear espacios de trabajo aislados para trabajar en varias tareas del mismo repo a la vez, repartiendo no solo los ficheros sino también el runtime: worktree propio, rango de puertos reservado, base de datos separada y fichero de entorno derivado. Usa cuando vayas a lanzar varias tareas en paralelo sobre un repo, cuando necesites tocar dos ramas a la vez sin hacer stash, o cuando dos procesos se estén peleando por el mismo puerto.
---

# workspace

Un worktree de git aísla los ficheros. **El runtime no.** Es la parte que se
olvida, y es la que hace daño: dos tareas en paralelo sobre el mismo repo
siguen peleándose por el puerto, por la base de datos y por el fichero de
entorno. El conflicto que creías haber eliminado reaparece como datos
corrompidos, que es peor que un conflicto de merge porque es silencioso.

Esta skill reparte las dos cosas.

## Uso

```bash
crux workspace new <nombre>      # desde el repo, o con --repo <dir>
crux workspace new <nombre> --branch fix/algo    # elige el nombre de la rama
crux workspace list
crux workspace rm <nombre>
```

`new` crea el worktree en una rama nueva, reserva el primer slot libre, escribe
el fichero de entorno con los valores de ese slot y lo registra. `rm` libera
todo, y **se niega a borrar un espacio con cambios sin commitear**.

**El nombre del espacio es local; el de la rama se publica.** Por defecto la
rama es `ws/<nombre>`, que en un repo propio está bien. En el de un cliente esa
rama acaba visible en su repositorio, con nuestra nomenclatura y con el idioma
que lleve el nombre: ahí se fija con `--branch`. El comando avisa cuando el
perfil es `client-repo` y no se ha elegido.

## Configurar el reparto

En el `crux.json` del proyecto, sección `workspace`:

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

Sustituciones disponibles: `{{SLOT}}`, `{{PORT0}}` … `{{PORTn}}` dentro del
rango del slot, `{{NAME}}` y `{{BRANCH}}`.

Sin esta sección solo se reserva el rango de puertos y se avisa. **Merece la
pena rellenarla**: es la diferencia entre poder lanzar dos tareas y poder
lanzar cinco.

## Qué hay que aislar, en orden de daño

1. **Puertos.** Lo obvio y lo primero que falla: el segundo proceso no arranca.
2. **Base de datos.** Lo peligroso: los dos procesos arrancan, funcionan, y se
   pisan los datos. Una base o un esquema por slot; en Redis, basta con un
   número de base distinto.
3. **Fichero de entorno.** Si los dos espacios leen el mismo `.env`, los dos
   puntos anteriores no sirven de nada.
4. **Volúmenes y cachés con estado.** Cachés en disco, directorios de subidas,
   índices de búsqueda. Si dos espacios comparten uno, hereda sus efectos.
5. **Recursos externos compartidos.** Un webhook, una cola, un bucket de
   pruebas. Aquí normalmente no puedes aislar: asúmelo y no lances en paralelo
   tareas que los toquen.

## Por qué el worktree va como hermano del repo

El espacio se crea en `<repo>-ws-<nombre>`, al lado del repo original, y no en
un directorio de trabajo aparte. Es deliberado: **el estándar apoya los
punteros de contexto en rutas relativas** (`../<project>-docs/`), y desde un
directorio fuera del proyecto esas rutas no resuelven. El agente que trabaje en
el espacio aislado se quedaría sin el contexto del proyecto.

## Antes de lanzar tareas en paralelo

- **Reparte por superficie, no por fichero.** Dos tareas sobre módulos
  distintos van bien; dos sobre el mismo fichero acabarán en un conflicto que
  te toca resolver a ti.
- **Una tarea que va a tocar migraciones va sola.** El esquema es compartido
  aunque la base no lo sea, en cuanto vuelvan a la misma rama.
- **Nombra los espacios por la tarea**, no por su número: `fix-login` te dice
  qué hay dentro dentro de dos días; `ws-3`, no.

## La rama principal está cerrada

`crux hooks install` deja un `pre-push` que **rechaza el push directo a la rama
principal**. El trabajo entra por propuesta, no por empujón.

Es una red local, no una garantía: un `--no-verify` la salta. La protección de
verdad es del lado del servidor, y en un repo privado sin plan de pago no está
disponible. Esto cubre el descuido, que es el caso que ocurre de verdad.

## Perfiles de cliente

Si el proyecto declara un perfil que prohíbe escribir fuera del docs repo, el
comando **se niega**: un worktree crea una rama en el repo de origen, y eso es
escribir en código ajeno.

Se puede forzar con `--force` cuando el cliente lo autoriza expresamente. Que
haga falta un flag es a propósito: obliga a que sea una decisión, no un
descuido.

## La tarea del espacio

Al abrirlo, el espacio registra su tarea en `~/.crux/tasks/<proyecto>/<tarea>.md`.
Si la tarea toca otro repo, se abre allí un espacio con el mismo `--task`, y
los dos escriben en el mismo registro.

```bash
crux workspace new <tarea> --goal "qué y por qué"
crux task                          # estado, pasos y siguiente paso
crux task add "paso" "otro paso"   # devuelve T1, T2…
crux task done T1 "lo que lo prueba"
crux task next "lo siguiente"
crux task note "desviación del plan"
crux task note "qué se decidió" --why "por qué" --where "dónde vive" --learned "qué se aprendió"
```

**Una decisión se anota en el momento y con su porqué.** Las notas con `--why`
pasan solas a `repos/<repo>/notes.md` del docs repo al archivar la tarea; las
que no lo llevan se quedan en el registro, que es local.

**Se escribe en el idioma de las propuestas del repo** —el de sus commits—,
porque de ahí sale la descripción. `workspace new` lo dice al abrir el espacio.

**Se anota mientras se trabaja, no al final**: es lo que permite retomar tras
una interrupción sin reconstruir nada, y lo que después cuenta la propuesta.
`ship seal` añade lo comprobado y `finish` saca de ahí la descripción.

## Cerrar el ciclo

```bash
crux workspace finish <nombre>          # sube la rama y abre la propuesta
crux workspace merge <nombre>           # enseña el estado, no fusiona
crux workspace merge <nombre> --yes     # fusiona, si nada lo bloquea
```

`finish` se niega si queda algo sin commitear o si el commit no ha pasado la
puerta de calidad: así no se propone código que nadie ha revisado.

`merge` mira tres cosas antes de dejar fusionar —comprobaciones automáticas,
conflictos y cambios solicitados en la revisión— y **nunca fusiona sin `--yes`**.
Que haga falta el flag es el punto: la decisión es de una persona, y el comando
solo se asegura de que llega informada.

**Si el repo no tiene comprobaciones automáticas, lo dice.** "Nada lo bloquea"
no es lo mismo que "está verificado": sin CI, la única red es la que pasaste en
local.

## Al terminar

**Un espacio se cierra con `crux workspace rm`, nunca con `git worktree remove`
ni `rm -rf`**: el atajo deja la entrada en el registro y la tarea sin cerrar, y
un hook lo para. `crux workspace merge --yes` ya cierra el espacio al fusionar.
Un worktree creado a mano se registra con `crux workspace adopt <ruta>`.

`crux workspace rm <nombre>` libera el worktree y el slot. La rama sobrevive a
propósito: el espacio es desechable, el trabajo no. Si era el último espacio de una tarea ya
fusionada, la tarea se archiva; si no está terminada, se queda abierta.

## Relacionado

- `/ship` — la puerta de calidad antes de commitear lo que salga de un espacio
