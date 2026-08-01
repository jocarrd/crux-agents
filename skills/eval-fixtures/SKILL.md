---
name: eval-fixtures
description: Probar funcionalidad construida sobre un modelo de lenguaje, donde la salida no es determinista y un test de igualdad exacta no sirve: separar lo que sí se puede afirmar, validar estructura en vez de texto, montar un conjunto de casos con salidas juzgadas y vigilar la regresión. Usa cuando el proyecto tenga un chatbot, generación de texto, extracción, clasificación o llamada a herramientas, y quieras poder cambiar el prompt o el modelo sin romper nada a ciegas.
---

# eval-fixtures

Un test normal no vale para una salida generada: dos ejecuciones no dan lo
mismo, y aunque dieran, la respuesta correcta no es única. Pero **la mayoría de
los fallos reales no son de calidad literaria**: son estructurales, y esos sí
se pueden atrapar.

## Las tres capas

Se prueban cosas distintas en cada una, y confundirlas es el error habitual.

**1. Determinista — todo lo que rodea al modelo.**
El montaje del prompt, el parseo de la respuesta, la validación del esquema, el
manejo de errores y timeouts, el enrutado de herramientas. Aquí el modelo se
sustituye por un doble con respuestas fijas y se testea como cualquier otro
código. **Es donde está la mayoría de los bugs** y donde casi nadie mira.

**2. Estructural — la forma de la salida.**
Con el modelo de verdad, pero sin comparar texto: que la respuesta cumpla el
esquema, que los campos obligatorios estén, que los tipos y rangos sean
válidos, que las herramientas llamadas existan y reciban los argumentos con la
forma correcta, que no se invente identificadores.

Esta capa es barata, estable y **atrapa las regresiones de verdad**: cuando
cambia el modelo o el prompt, lo primero que se rompe es la forma.

**3. De calidad — el contenido.**
Un conjunto de casos con su salida esperada y un criterio de aceptación. No es
igualdad: es un umbral. Aquí se mide si la respuesta está fundamentada en los
datos que se le dieron, si responde lo que se preguntó y si respeta las reglas
del dominio.

## El conjunto de casos

Es el activo, más que los tests. Se construye **desde los fallos reales**, no
imaginando ejemplos:

- Cada vez que alguien reporta una respuesta mala, entra al conjunto.
- Cada caso límite del dominio que descubras, entra.
- Los casos donde la respuesta correcta es "no lo sé" — los más olvidados y los
  que más daño hacen cuando el modelo inventa.

Cada caso guarda: la entrada, el contexto que se le dio, qué debe cumplir la
respuesta y por qué. Ese "por qué" es lo que permite revisar el criterio
cuando cambie el producto.

Empieza con veinte casos bien elegidos. Doscientos generados sin criterio no
valen más y cuestan cada ejecución.

## Qué se puede afirmar sin ambigüedad

Aunque la salida sea libre, casi siempre hay afirmaciones duras:

- **No inventa datos**: todo número, nombre o identificador de la respuesta
  aparece en el contexto que se le pasó.
- **Respeta los límites**: no promete lo que el producto no hace, no da
  consejos que la política prohíbe.
- **Es consistente**: la misma pregunta con el mismo contexto no da respuestas
  contradictorias entre ejecuciones.
- **Falla bien**: sin datos suficientes, dice que no lo sabe en vez de rellenar.

Empieza por estas. Son objetivas y cubren el daño más caro.

## Vigilar la regresión

El valor aparece cuando cambias algo: prompt, modelo, versión, contexto
recuperado. Sin una línea base, cada cambio es una apuesta.

Guarda el resultado del conjunto como referencia y compara. Lo que interesa no
es la nota absoluta, sino **qué casos pasaban antes y ahora no**. Un cambio que
sube la media y rompe tres casos que funcionaban suele ser un mal cambio.

## Coste

Estas pruebas cuestan dinero y tiempo por ejecución, así que no van en el mismo
sitio que los tests normales:

- La capa 1 corre siempre: es gratis y rápida.
- Las capas 2 y 3 corren **cuando cambia algo que las afecta** —prompt, modelo,
  recuperación de contexto— y antes de desplegar. No en cada commit.

## Anti-patterns

- **Comparar la salida con un texto exacto.** Se rompe siempre y no prueba
  nada.
- **Probar solo el camino feliz.** Lo que hunde un asistente es lo que hace
  cuando no sabe.
- **Fiarse solo de la nota media.** Esconde exactamente las regresiones que
  buscas.
- **Un conjunto de casos inventado.** Los casos que se te ocurren no son los que
  fallan; los que te reportan, sí.
- **Testear el modelo en vez de tu sistema.** Que el modelo sepa sumar no es tu
  problema; que tu prompt le dé los datos correctos, sí.

## Relacionado

- `/write-tests` — la capa 1 es esto, con un doble en medio
- `/root-cause` — cuando una respuesta concreta sale mal y hay que entender por
  qué
