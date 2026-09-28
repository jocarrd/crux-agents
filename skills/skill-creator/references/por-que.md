# Por qué las skills se escriben así

El procedimiento está en `SKILL.md`. Aquí están los motivos y lo que se midió.

## Por qué el tamaño importa

Cada skill se carga entera en el contexto del agente cada vez que se usa, y el
contexto lleno rinde peor y cuesta más. Medido el 28-09-2026 con un prompt fijo
y el tokenizador del modelo:

| Skill | Antes | Acortada | Ahorro |
| ----- | ----- | -------- | ------ |
| `ship` | 2.821 tokens | 1.533 | 46 % |
| `flow` | 3.334 | 1.390 | 58 % |
| `review-pr` | 3.473 | 1.890 | 45 % |
| `x-posts` | 4.146 | 1.897 | 54 % |
| `share-local` | 2.850 | 1.480 | 48 % |
| `visual-test` | 2.619 | 1.300 | 51 % |

Casi la mitad de cada skill era explicación de por qué existía cada regla. Con
tres escenarios de respuesta conocida, las versiones cortas respondieron como
las originales, una vez corregidos dos matices que el primer borrador había
perdido.

Traducir al inglés ahorraba menos: `ship` pasaba de 2.821 a 2.203 tokens (22 %).
En castellano, cada palabra ocupa de media casi el doble de tokens, así que
1.000 palabras son unos 1.900 tokens.

## Por qué probar con escenarios

Los dos errores que salieron al acortar:

- `review-pr` perdió qué cuenta como "solo texto", y el primer borrador dejaba
  fusionar sin preguntar un cambio de CSS, que el script trata como código.
- `visual-test` dejaba dar por buena una página con solo `audit` y `checks`,
  sin mirar las capturas.

Ninguno se veía leyendo: el texto corto parecía completo. Se vieron al comparar
las respuestas de las dos versiones a la misma pregunta. Por eso el matiz que
cambia una decisión va en `SKILL.md`, no en la referencia: la referencia solo se
abre si el agente duda, y cuando pierde un matiz no duda.

## Por qué buscar antes de crear

Dos skills que responden a la misma frase se quitan la activación la una a la
otra, y el agente acaba eligiendo la peor. Ampliar una existente mantiene el
catálogo corto, que también es contexto: el agente ve una línea de cada skill
en cada sesión.

## Por qué la descripción manda

Es lo único que el agente lee antes de decidir. Una skill que no se activa
cuando toca es como si no existiese. Los síntomas se escriben como los diría
quien tiene el problema, porque esa persona todavía no sabe que necesita esta
skill.

"Cuándo no usar" evita aplicar un procedimiento caro a un caso trivial.

## Por qué los gotchas valen más

El procedimiento feliz lo deduce cualquiera. Lo que no se deduce es que cierta
capa de fabricante bloquea los toques, que sin cancelar las animaciones la
salida sale en blanco, o que la variante de media manda sobre la clase base.

## Por qué el adaptador tiene que repartir

El adaptador y el procedimiento que adapta comparten vocabulario, y eso es
inevitable. El problema es cuando el adaptador gana también las frases sin
nombres propios: el catálogo es común a todos los proyectos y entonces gana
donde no aplica. Las dos frases se escriben antes de la descripción, como se
pediría el trabajo de verdad; sacarlas de la descripción ya escrita hace que la
prueba pase siempre.

## Por qué ejecutarla

Escrita desde la memoria siempre le falta un paso: los que diste por supuestos
solo aparecen al seguirla al pie de la letra.
