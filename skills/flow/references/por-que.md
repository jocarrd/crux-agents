# Por qué el ciclo es así

El procedimiento está en `SKILL.md`. Aquí está el motivo de cada paso, para
cuando haya que decidir si saltárselo tiene sentido.

## Aislar antes de empezar

Es lo que evita el problema más caro de trabajar con varios agentes: dos
sesiones sobre el mismo directorio se pisan los ficheros, mezclan sus cambios en
el mismo commit y se pelean por el puerto y la base de datos. La rama nace
separada y es la misma que acaba siendo la propuesta, así que el trabajo sale
como algo que se revisa y no como cambios sueltos mezclados con los de otro.

Aislar después de empezar obliga a mover cambios entre ramas, que es justo el
lío que se quería evitar.

## Preguntar y planificar antes del código

Un turno de preguntas sale más barato que un diff construido sobre una
suposición. Un plan que dice "voy a cambiar el formato de la clave de caché" se
rechaza en cinco segundos; el mismo error descubierto después es un diff que
revisar y probablemente revertir.

## Tests y depuración durante, no al final

Los tests escritos después se escriben para que pasen. Cambiar cosas a ver si
funcionan es lo que convierte un bug en dos.

## Enseñar antes de proponer

Va después de `/ship` para que lo que se enseña sea exactamente lo que se va a
proponer, y antes de `finish` porque proponer ya es enseñar el trabajo a otros.

## Proponer y esperar al CI

`finish` se niega sin commit o sin puerta porque lo que no está en git no llega
a la revisión, y así no se abre una propuesta de código que nadie ha revisado.

Esperar al CI delante de la pantalla bloquea la sesión minutos en los que nadie
avanza. El rigor está en no dar por buena la propuesta hasta ver el resultado,
y eso se cumple igual mirándolo después. El límite de tres intentos existe
porque seguir empujando arreglos a ciegas deja una rama con diez commits de
"fix ci": si al tercero sigue en rojo, el problema no era el que parecía.

## Revisar desde otro contexto

`/ship` pregunta si está listo lo que hiciste; `/review-pr` pregunta si es
correcto y completo lo que se propone, y lo pregunta alguien que no estaba
dentro del problema. Es la diferencia entre revisar y confirmar.

## Fusionar y vigilar

La decisión de fusionar es de una persona; el comando solo se asegura de que
llega informada. "Nada lo bloquea" no es lo mismo que "está verificado". Si no
se vigila el despliegue, el primero que ve el fallo es un usuario.

## Cerrar

Lo aprendido que no queda en el código se pierde con la sesión, y en tres meses
alguien vuelve a descubrirlo.

## Lo que se paga al saltarse cada paso

| Paso | Si te lo saltas |
| ---- | --------------- |
| Entender | Escribes código para averiguar lo que la documentación ya dice |
| Aislar | Te mezclas con otra sesión y resuelves conflictos que no existían |
| Preguntar | Construyes bien lo que no era, y se ve al enseñarlo |
| Planificar | Descubres el error cuando ya es un diff |
| Tests durante | Los escribes para que pasen, no para que fallen |
| La puerta | Entra trabajo roto, y se descubre en producción |
| Enseñar | Se propone lo que quien decide no ha visto |
| Proponer | El cambio no se revisa, o se revisa ya integrado |
| Esperar al CI | El rojo se descubre al ir a fusionar, sin contexto |
| Fusionar | Entra sin mirar el CI ni los conflictos |
| Vigilar el despliegue | El primero que ve el fallo es un usuario |
| Cerrar | Lo aprendido muere con la sesión |
