---
name: redaccion
description: Escribir y revisar textos que no se lean como generados por un modelo. Da la lista concreta de marcadores que delatan un texto de IA —regla de tres, paralelismo negativo, raya larga, epigramas, vocabulario recurrente, grandilocuencia—, un script que los cuenta sobre el texto real, y el método para reescribir sin caer en ellos. Usa al redactar cualquier texto que vaya a leer otra persona: documentación, presentaciones, mensajes de commit, correos, propuestas y textos de interfaz. Y siempre antes de entregar un documento a un cliente.
---

# redaccion

Un texto generado se reconoce por su forma antes que por su contenido. Los
marcadores son pocos, concretos y se pueden contar. Esta skill los enumera y
trae un script que los mide, para que revisar no dependa de leerlo con buen ojo.

## Cuándo usar

- Antes de entregar cualquier documento a un cliente o a alguien de fuera.
- Al escribir documentación, una presentación, una propuesta o un correo largo.
- Cuando alguien dice que un texto «suena a IA» y hay que arreglarlo de raíz.

## Los siete marcadores

Ordenados por lo que más delata. Los tres primeros bastan para reconocer un
texto generado sin leer una palabra de su contenido.

### 1. Paralelismo negativo

La construcción «no es X, es Y» y sus variantes: «X, no Y», «no se trata de X,
sino de Y», «más que X, es Y».

> Un plan no se escribe para documentar. Se escribe para que alguien lo pare.
> Un tono no es un color: es un papel.
> Se mide, no se estima.

Es la figura que más aparece y la que menos se justifica. Casi siempre se puede
decir la parte afirmativa sola, que además es la que lleva la información.

**Cómo se arregla:** quita la negación y quédate con lo que afirmas.
«Un plan sirve para que alguien lo pare a tiempo.»

### 2. Regla de tres

Tres adjetivos, tres sintagmas o tres cláusulas coordinadas donde el contenido
solo pedía uno o dos. Sirve para que un análisis superficial parezca completo.

> Radios, trazos y una sola sombra.
> Se admite el movimiento que orienta, sitúa o explica.
> Claro, sencillo y directo.

**Cómo se arregla:** cuenta los elementos de cada enumeración. Si el tercero no
añade nada que no esté en los dos primeros, sobra. Si los tres son necesarios,
no es un tic.

### 3. Epigrama como titular

Titulares que son una frase ingeniosa en vez de una etiqueta. En un documento
de referencia, el titular sirve para encontrar la página, no para lucirse.

> «Cómo se llaman las cosas» en vez de «Terminología».
> «Lo que toda pieza tiene que cumplir» en vez de «Requisitos».
> «El logo y su aire» en vez de «Área de protección».

**Cómo se arregla:** usa el término estándar del oficio. Si no lo sabes,
búscalo. Casi todos los sectores tienen su vocabulario fijado, y usar otro
llama la atención sobre el autor en lugar de sobre el contenido.

### 4. Raya larga en exceso

La raya larga (—) donde un humano habría puesto una coma, un paréntesis, dos
puntos o punto y seguido. Aparece sobre todo para dar énfasis a una aposición.

**Cómo se arregla:** una o dos por documento, no una por párrafo. Sustituye
por coma cuando el inciso es breve y por paréntesis cuando es una aclaración.

### 5. Dos puntos aforísticos

Dos puntos en mitad de una frase para rematar con una sentencia. Es la misma
pulsión que el epigrama, a escala de oración.

> El resultado es claro: no funciona.
> Y ahí está el problema: nadie lo mide.

**Cómo se arregla:** punto y seguido, o reescribe como una sola afirmación.

### 6. Vocabulario recurrente

Palabras que un modelo elige mucho más que una persona. En castellano:

`clave` · `fundamental` · `crucial` · `robusto` · `sólido` · `potente` ·
`riguroso` · `profundizar` · `panorama` · `enfoque` · `en última instancia` ·
`cabe destacar` · `es importante señalar` · `no solo… sino también` ·
`permite` (como verbo comodín) · `garantizar` · `optimizar` · `impulsar`

**Cómo se arregla:** sustituye por el verbo o el sustantivo concreto. «Permite
mejorar la legibilidad» → «se lee mejor».

### 7. Grandilocuencia

Inflar la importancia de algo conectándolo con un tema más amplio, o cerrar un
apartado con una reflexión que no aporta dato.

> Lo que hace consistente a una marca no es que las pantallas se parezcan.
> Esto es lo que separa un dato de una afirmación.

**Cómo se arregla:** bórralo. Si la frase no añade un hecho, una cifra o una
instrucción, no está haciendo nada.

## Cómo revisar

```bash
node scripts/redaccion.mjs revisar <fichero…>     # cuenta los siete marcadores
node scripts/redaccion.mjs revisar --texto "…"    # sobre una cadena suelta
node scripts/redaccion.mjs detalle <fichero>      # enseña cada caso en su línea
```

El script cuenta y localiza. Decidir si cada caso sobra te toca a ti. Hay
textos donde una regla de tres es exactamente lo que pide el contenido.

De los siete, **solo cinco puntúan**. La raya larga y los dos puntos se
informan aparte, porque una expresión regular no distingue un remate de una
explicación: «no vale para una salida generada: dos ejecuciones no dan lo
mismo» es uso correcto, y el script no puede saberlo.

**Umbral orientativo** para un documento de unas 2.000 palabras. Cero
paralelismos negativos. Menos de tres reglas de tres. Ningún titular
epigramático. Por encima de eso, se nota.

## Falsos positivos conocidos

Tres familias que el script ya excluye, y que conviene no volver a meter:

- **«clave»** en castellano técnico suele ser una clave SSH, no el adjetivo.
  Solo cuenta cuando va de adjetivo: «un factor clave», «es clave para».
- **«lo que hace falta»** es un giro corriente, y contiene «lo que hace».
- **Los dos puntos que abren una enumeración** son uso normal. El tic es
  rematar la frase con una sentencia.

## Lo que esta skill no arregla

El registro. Un texto puede pasar los siete marcadores y seguir sin servir
porque usa jerga que su lector no conoce, o porque explica lo que no hacía
falta y calla lo que sí. Antes de revisar la forma, pregúntate quién lo lee y
qué necesita saber.

Y una advertencia. Perseguir estos marcadores hasta el extremo produce prosa
plana. Una raya larga bien puesta y una enumeración de tres que de verdad tiene
tres cosas son buena escritura. El objetivo es que la figura aparezca cuando el
contenido la pide, no como relleno rítmico.
