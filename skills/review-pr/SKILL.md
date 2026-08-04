---
name: review-pr
description: Revisar el código de una propuesta ya abierta con criterio de revisor y no de autor: si el diff hace lo que dice, si el arreglo está completo, si los tests prueban comportamiento, si encaja con lo que el repo ya hace, y qué deuda deja. Usa justo después de abrir una propuesta de cambio, antes de pedir revisión humana, cuando heredes la propuesta de otra sesión, o cuando el cambio lo haya escrito un agente.
---

# review-pr

La propuesta ya está abierta. Esto es lo que pasa **entre abrirla y que alguien
la mire**, y es donde se cazan las cosas que el autor no puede ver: no por
descuido, sino porque estaba dentro del problema.

## Por qué no lo cubre `/ship`

Responden preguntas distintas.

`/ship` pregunta **"¿está listo lo que hice?"** — tests en verde, diff leído,
sin regresiones. Es la puerta del autor, y se pasa antes de commitear.

Esto pregunta **"¿es correcto y completo lo que se propone?"** — mirando el
cambio entero, ya reposado, contra lo que el repo hace y lo que la propuesta
promete. Un cambio puede pasar `/ship` limpio y seguir estando incompleto: los
tests que escribió el autor prueban lo que el autor pensó.

El caso típico: se arregla un agujero por la puerta por la que se encontró, y
la misma entrada llega por otra que nadie miró.

## La condición que lo hace funcionar

**Se revisa desde un contexto independiente del que escribió el cambio.** Un
hilo que acaba de defender cada decisión no está en posición de refutarlas:
tiende a confirmar lo que ya concluyó, y además arrastra todo el razonamiento
previo como si fuera evidencia.

Si el entorno permite lanzar una revisión aislada, se usa. Si no, se abre
sesión nueva y se entra **solo con el diff y la descripción de la propuesta**,
sin el historial de cómo se llegó ahí.

## Qué se pone delante

```bash
crux review
```

Reúne los commits, el diff contra la base, la propuesta con sus comprobaciones
y unas señales objetivas —código sin tests, marcadores de trabajo a medias,
credenciales aparentes, dependencias tocadas, ficheros que se han ido de
tamaño—. No revisa: prepara, para que la revisión no dependa de que alguien se
acuerde de juntarlo.

Falta una cosa más, que no la da ningún comando: **las convenciones del repo**.
Están escritas en su documentación; no se adivinan.

## El recorrido

En este orden, porque cada uno depende del anterior.

### 1. Fidelidad

¿El diff hace lo que la propuesta dice, **y solo eso**? Ficheros tocados que
no vienen a cuento, formateo mezclado con lógica, restos de depuración,
código muerto que se quedó.

### 2. Completitud del arreglo

La pregunta que más rinde: **¿por dónde más entra esto?** Si se validó una
entrada, ¿hay otro comando que la acepte sin validar? Si se arregló un
cálculo, ¿quién más lo hace? Un arreglo parcial es peor que ninguno, porque
cierra el asunto en la cabeza de todos.

### 3. Correctitud

Casos límite, valores vacíos, errores no gestionados, condiciones invertidas,
orden de operaciones. Para cada sospecha: **reprodúcela antes de escribirla**.

### 4. Tests

- ¿Existen para lo que cambió?
- ¿**Fallan sin el arreglo**? Un test que pasa en las dos versiones no prueba
  nada. Comprobarlo cuesta un minuto: se revierte el código, se corre, se
  restaura.
- ¿Prueban comportamiento o fijan la implementación actual? Los segundos
  convierten cualquier refactor futuro en trabajo de reescribir tests.
- ¿Cubren el camino de fallo, o solo el feliz?

### 5. Consistencia

¿Esto se parece a lo que el repo ya hace? Utilidades que se reinventan
existiendo, dos formas distintas de lo mismo en el mismo diff, nombres que no
siguen la convención de al lado, dependencias nuevas para algo que ya estaba
resuelto.

### 6. Legibilidad

Se lee una vez, del tirón: ¿se entiende qué hace y por qué? Comentarios que
narran lo que el código ya dice sobran; los que explican el porqué que no se
deduce, faltan cuando no están.

### 7. Deuda y ruido

Duplicación introducida, abstracciones de más, ficheros que crecen sin
partirse. Vale la pena mirarlo aparte: **el código escrito con asistencia tiende
a añadir redundancia por cambio**, y el diff parece limpio porque cada trozo,
por separado, lo es.

### 8. Superficie sensible

Secretos o credenciales en el diff, entradas que llegan a una ruta o a una
consulta sin validar, permisos, dependencias nuevas y de dónde salen.

## Cómo se escribe un hallazgo

Cuatro cosas, o no se escribe:

```
fichero:línea — qué ocurre
por qué importa: la consecuencia concreta
qué lo arregla: la línea, no el sermón
```

Lo que no vale: «considera mejorar el manejo de errores», «esto podría tener
problemas de rendimiento». Suena a revisión y no dice nada; quien lo lee no
sabe si tocar algo ni dónde.

## Verificar antes de publicar

Cada hallazgo se confirma —reproduciéndolo, o citando la línea que lo
demuestra— antes de salir. **Los que no se confirman se caen**, no se publican
con un "quizá".

Una revisión con tres hallazgos ciertos se lee entera. Una con quince, de los
que cuatro son ruido, enseña a ignorar la siguiente.

## Qué se hace con ellos

- **Confirmado y claro**: se arregla en la misma rama, con su test, y se pasa
  `/ship` otra vez. La propuesta se actualiza sola.
- **Confirmado y discutible** —afecta al diseño, o al alcance—: se publica en la
  propuesta y lo decide quien la revisa.
- **Dudoso**: no se publica. Se comprueba primero.

## Contárselo a quien decide

**La revisión no termina en la propuesta: termina contada.** Un comentario en
un hilo que nadie abre hasta la semana siguiente no es una revisión, es un
archivo. Quien tiene que decidir necesita saberlo ahora y en su idioma, no en
jerga de diff.

Tres cosas por hallazgo, y en este orden:

1. **Qué está mal** — en una frase, sin rodeos.
2. **Qué cambiarías** — concreto: el fichero, la línea, el arreglo. Si ya está
   hecho, se dice que está hecho.
3. **Por qué importa** — la consecuencia real si se queda. Sin esto, todo
   parece igual de urgente y quien decide no puede priorizar.

Y con esto alrededor:

- **Ordenado por lo que costaría si pasa**, no por fichero ni por orden de
  aparición. Lo primero que se lee es lo que más duele.
- **Separando lo arreglado de lo que necesita decisión.** Confundirlos hace que
  parezca que hay más trabajo pendiente del que hay.
- **Diciendo qué se revisó y no tenía nada.** Si no, el silencio se lee como
  "no lo miré", y la siguiente revisión ya no se cree.
- **Diciendo qué no se revisó.** Una revisión sin alcance declarado se lee como
  si lo cubriera todo.

Si no hay ningún hallazgo, también se cuenta: qué se miró, con qué criterio, y
por qué no salió nada. Es información, no un trámite.

## Anti-patterns

- **Revisar en el mismo hilo que escribió el código.** Confirma, no refuta.
- **Resumir el diff y llamarlo revisión.** El resumen ya está en la propuesta.
- **Publicar sospechas sin reproducir.** Cada falso positivo hace más caro el
  siguiente hallazgo de verdad.
- **Mirar solo lo que el diff toca.** La pregunta del punto 2 —por dónde más
  entra— vive fuera del diff.
- **Aprobar porque los tests pasan.** Los escribió quien hizo el cambio.
- **Dejarlo para después de fusionar.** Después ya no es una propuesta, es el
  código del repo.
- **Dejar los hallazgos solo en la propuesta.** Quien decide no está mirando el
  hilo; se le cuenta.

## Relacionado

- `/ship` — la puerta del autor, aguas arriba de esto
- `/flow` — el ciclo completo; esto es su paso 6a
- `/root-cause` — cuando un hallazgo necesita depurarse antes de escribirlo
- `/write-tests` — para el test que falta cuando el hallazgo es real
