# Por qué la revisión es así

El procedimiento está en `SKILL.md`. Aquí está el motivo de cada regla.

## No lo cubre `/ship`

Un cambio puede pasar `/ship` limpio y seguir incompleto: los tests que
escribió el autor prueban lo que el autor pensó. El caso típico es arreglar un
agujero por la puerta por la que se encontró, mientras la misma entrada llega
por otra que nadie miró.

## Contexto independiente

Un hilo que acaba de defender cada decisión no está en posición de refutarlas:
tiende a confirmar lo que ya concluyó y arrastra el razonamiento previo como si
fuera evidencia.

## `crux review` prepara, no revisa

Reúne el material para que la revisión no dependa de que alguien se acuerde de
juntarlo. Las convenciones no las da ningún comando: están escritas en la
documentación del repo y no se adivinan.

## Por qué no se lanzan todos los especialistas

Cada uno cuesta entre 20.000 y 50.000 tokens según el tamaño del cambio. Cuatro
en cada propuesta multiplican por cinco el coste de revisar, y la mayoría no
encontraría nada: un cambio de estilos no tiene consultas ni permisos. Con el
reparto por diff, las erratas no lanzan ninguno, una pantalla lanza el de
interfaz, y un endpoint con sesión o una migración lanzan dos o tres, que es
donde se pagan solos porque el fallo no se ve en una captura.

No todo proyecto merece la misma ceremonia; por eso el rigor mueve los
umbrales.

## El orden del recorrido

Cada paso depende del anterior. La completitud es la pregunta que más rinde: un
arreglo parcial es peor que ninguno, porque cierra el asunto en la cabeza de
todos. Un test que pasa con y sin el arreglo no prueba nada, y comprobarlo
cuesta un minuto. Los tests que fijan la implementación convierten cualquier
refactor futuro en reescribir tests.

La deuda se mira aparte porque el código escrito con asistencia tiende a
añadir redundancia en cada cambio, y el diff parece limpio porque cada trozo,
por separado, lo es.

## Hallazgos confirmados y bien escritos

«Considera mejorar el manejo de errores» suena a revisión y no dice nada: quien
lo lee no sabe si tocar algo ni dónde. Una revisión con tres hallazgos ciertos
se lee entera; una con quince, de los que cuatro son ruido, enseña a ignorar la
siguiente.

## Dos rondas como mucho

Una tercera vuelta no converge: persigue lo que la anterior rompió, y cada
pasada encuentra algo nuevo porque vuelve a mirar entero.

## Contarlo

Un comentario en un hilo que nadie abre hasta la semana siguiente queda
archivado sin más. Sin el porqué, todo parece igual de urgente y quien decide no
puede priorizar. Si no se dice qué se revisó sin encontrar nada, el silencio se
lee como "no lo miré"; una revisión sin alcance declarado se lee como si lo
cubriera todo. Después de fusionar, lo que se encuentre ya forma parte del
código del repo.
