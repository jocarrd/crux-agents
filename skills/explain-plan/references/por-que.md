# Por qué el plan es así

El procedimiento está en `SKILL.md`.

## Un plan se escribe para pararlo

Un plan que dice "voy a cambiar el formato de la clave de caché" se rechaza en
cinco segundos con "no, eso rompe las claves existentes, usa un prefijo
versionado". El mismo arreglo después de escribir el código es un diff que
revisar y probablemente revertir.

## La traza

Es la sección que casi nadie escribe y la que hace útil el plan. Quien lee no
tiene que reconstruir tu razonamiento ni fiarse de él: lo verifica. Y obliga a
la especificidad: al escribir "comprobé X y resultó Y" descubres las veces que
en realidad no lo comprobaste.

## El reverso

Distingue una decisión de ida y vuelta de una de un solo sentido, y por tanto
cuánto había que pensarla. Un `git revert` baja el listón de la discusión.

## Las alternativas con motivo

Evitan repetir el mismo análisis dentro de tres meses, y permiten que alguien
diga "ese motivo ya no aplica, reabramos".

## Lo que no sé

Un plan que finge cubrirlo todo es peor que uno que señala sus huecos: el hueco
sigue ahí y ahora además está escondido.

## La forma

Una tabla permite decidir de un vistazo, que es el objetivo. Un diagrama de
secuencia evita reconstruir el orden de memoria; un grafo enseña de golpe lo que
no se ve leyendo. El porqué y los riesgos no caben en una tabla sin perder el
matiz, y tres números no necesitan ejes. Un diagrama transmite lo mismo que la
prosa a menos coste, cuando hay algo que dibujar.

## Cerrar el plan

Un plan aprobado y ejecutado sin desviaciones es raro. Las desviaciones son
decisiones tomadas con el código delante y más información que al escribirlo;
si no quedan escritas, se pierde justo lo que costó descubrir. Es la misma
regla que la sincronización entre código y documentación, aplicada al documento
que produjiste tú.

## Los anti-patrones

Un flujo de cuatro cajas obvias hace parecer el plan más profundo de lo que es.
Una lista de pasos no dice nada discutible. La plantilla completa por costumbre
es el modo de fallo de los RFC: se rellenan secciones que no aportan, sube el
detalle y la gente deja de leerlos; cinco secciones cortas se leen, doce no. Sin
la traza, aprobar es confiar, y confiar no es revisar.
