---
name: bug-hunt
description: Buscar fallos que nadie ha reportado todavía en una herramienta propia —comandos, scripts, instaladores—, ejercitándola en un entorno desechable con las entradas que nadie prueba, y midiendo cada hallazgo antes de proponer el arreglo. Usa cuando quieras endurecer algo que ya funciona, antes de enseñárselo a alguien de fuera, después de una tanda de cambios grande, o cuando te pidan "busca bugs" o "a ver si esto aguanta".
---

# bug-hunt

Buscar fallos que aún no ha reportado nadie. `/root-cause` depura un fallo que
ya tienes; esto encuentra los que todavía no sabes que tienes.

La idea central: **el camino feliz ya lo ha recorrido su autor**. Los fallos
viven en los bordes —lo corrupto, lo ausente, lo simultáneo, lo repetido— y en
el diagnóstico, que casi siempre está peor probado que la funcionalidad.

## Cuándo usar

- Vas a enseñar la herramienta a alguien de fuera y quieres que la primera hora
  no se estrelle.
- Acabas de meter varios cambios y no sabes qué se ha desalineado.
- Quieres endurecer algo que "ya funciona".

## Cuándo no usar

- **Tienes un fallo concreto delante**: eso es `/root-cause`.
- **Buscas deuda estructural** —duplicación, funciones enormes—: eso es
  `/code-health`. Aquí se buscan comportamientos incorrectos.
- Sobre código de terceros que no vas a poder arreglar.

## 1. Un entorno desechable, nunca los datos reales

Antes de nada, un lugar donde romper cosas sin consecuencias: directorio
temporal, variables de entorno redirigidas, credenciales falsas, remotos
locales en vez de servicios de verdad.

Si la herramienta escribe en el directorio del usuario, redirígelo también. Una
caza que ensucia el entorno real acaba costando más que los bugs que encuentra.

## 2. Recorrer primero el camino real

Ejercita el ciclo completo como lo haría alguien de fuera, del principio al
final, antes de tocar ningún borde. Esto calibra qué es normal y de paso caza
lo que esté roto de frente.

## 3. Después, los bordes

Los que dan resultado, por orden de rentabilidad:

- **Configuración corrupta.** No ausente: corrupta a medias. Un fichero de
  contrato con el JSON truncado descubre si el programa distingue "no está" de
  "no se puede leer".
- **Lo ausente donde siempre hubo algo.** Sin remoto, sin red, sin credencial,
  sin permisos.
- **Repetir.** Ejecuta dos veces lo mismo. La segunda ejecución revela lo que se
  duplica, lo que se pisa y lo que se rompe.
- **A la vez.** Lanza tres instancias en paralelo sobre el mismo recurso.
- **Nombres hostiles.** Espacios, acentos, barras, cadenas vacías.
- **El estado heredado.** Una configuración de una versión anterior, un
  directorio a medio migrar. Es el caso que solo sufre quien lleva tiempo
  usándolo, y por eso nunca está probado.

## 4. Antes de llamarlo bug: leer la intención

Muchas rarezas son decisiones. Antes de arreglar, busca la cabecera del fichero,
el comentario o la documentación que explique por qué es así. Si el
comportamiento es deliberado pero deja a quien lo usa sin salida, el arreglo
está en **decir cuál es el siguiente paso**.

## 5. Medir antes de proponer

Una mejora que parece obvia hay que **medirla contra los datos reales** antes de
escribirla. Aplica el cambio propuesto sobre el histórico y mira a cuántos casos
afecta y cuántos falsos positivos crea.

Descartar una mejora tras medirla también es trabajo hecho.

## 6. Un arreglo, un test que falle sin él

Por cada hallazgo, el test se valida **quitando el arreglo** y viendo el rojo.
Un test que pasa antes y después no prueba nada.

Y el test tiene que ejercitar **el comando de verdad**. Si copias su lógica
dentro del test para poder probarla, estás probando la copia. Cuando el comando
depende de algo externo, sustituye ese binario por uno de mentira en el PATH,
que devuelva lo que haga falta: eso mantiene el test sin red y sin dejar de
probar el código real.

## Gotchas que aparecen una y otra vez

Son de shell, pero el patrón se repite en cualquier lenguaje: **el error que se
traga se convierte en un dato falso**.

- **Silenciar la salida de error no cubre la redirección de entrada.** La
  resuelve el intérprete antes de ejecutar el comando, y su error sale igual.
- **Contar líneas con una herramienta que falla cuando no hay ninguna**, y
  encadenarle un valor por defecto, produce **dos** valores pegados.
- **Abortar al primer error dentro de un bucle** deja la tarea a medias y
  reporta éxito: el resto de elementos ni se intentan.
- **Preguntar si una rama está integrada** no funciona donde se integra
  aplastando los commits: hay que preguntar por la propuesta, no por el grafo.
- **Un valor por defecto deducido de la ruta de instalación** acierta en
  desarrollo y falla en producción, sin que nadie lo note durante meses.

## Cerrar

Borra el entorno desechable y comprueba que no queda nada fuera: procesos
levantados, ficheros temporales, ramas o recursos creados durante las pruebas.

## Relacionado

- `/root-cause` — cuando el fallo ya lo tienes delante
- `/write-tests` — cómo se escribe el test que acompaña al arreglo
- `/code-health` — deuda estructural, no comportamientos incorrectos
