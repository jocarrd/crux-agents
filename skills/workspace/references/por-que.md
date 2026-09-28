# Por qué los espacios de trabajo son así

El procedimiento está en `SKILL.md`.

## El runtime es lo que se olvida

Un worktree separa los ficheros y parece suficiente. Pero dos procesos que
comparten puerto no arrancan, y dos que comparten base de datos arrancan,
funcionan y se pisan los datos. Es peor que un conflicto de merge porque no
avisa. Rellenar la sección `workspace` del contrato es la diferencia entre poder
lanzar dos tareas y poder lanzar cinco. Si dos espacios leen el mismo `.env`,
aislar puertos y base de datos no sirve de nada.

## Por qué el worktree va al lado del repo

El estándar apoya los punteros de contexto en rutas relativas
(`../<project>-docs/`). Desde un directorio fuera del proyecto esas rutas no
resuelven, y el agente del espacio se quedaría sin el contexto del proyecto.

## El nombre de la rama

El nombre del espacio es local; el de la rama se publica. En el repo de un
cliente, `ws/<nombre>` acabaría visible con nuestra nomenclatura y en el idioma
del nombre.

## Perfiles de cliente

Un worktree crea una rama en el repo de origen, y eso es escribir en código
ajeno. Que haga falta `--force` obliga a que sea una decisión.

## Paralelo

Dos tareas sobre el mismo fichero acaban en un conflicto que resuelves tú. Las
migraciones van solas porque el esquema es compartido en cuanto las ramas
vuelven a juntarse. `fix-login` te dice qué hay dentro dentro de dos días;
`ws-3`, no.

## La rama principal cerrada

El `pre-push` rechaza el push directo a la principal de los repos de código y
del kernel. Un `--no-verify` lo salta: la protección de verdad es del lado del
servidor, y en un repo privado sin plan de pago no está disponible. Cubre el
descuido, que es el caso real. Los repos de docs se suben directos, como dice su
regla.

## Por qué `merge` pide `--yes` y `rm` deja la rama

La decisión de fusionar es de una persona; el comando solo se asegura de que
llega informada. El espacio es desechable y el trabajo no, por eso la rama
sobrevive a `rm`. El atajo de borrar a mano deja la entrada en el registro y la
tarea sin cerrar.
