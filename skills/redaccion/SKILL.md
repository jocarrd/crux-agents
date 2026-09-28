---
name: redaccion
description: Escribir y revisar textos que no se lean como generados por un modelo. Da la lista concreta de marcadores que delatan un texto de IA —regla de tres, paralelismo negativo, raya larga, epigramas, vocabulario recurrente, grandilocuencia—, un script que los cuenta sobre el texto real, y el método para reescribir sin caer en ellos. Usa al redactar cualquier texto que vaya a leer otra persona: documentación, presentaciones, mensajes de commit, correos, propuestas y textos de interfaz. Y siempre antes de entregar un documento a un cliente.
---

# redaccion

Un texto generado se reconoce por su forma antes que por su contenido. Los
marcadores son pocos, concretos y se cuentan con un script. Más ejemplos y el
porqué de cada regla: `<directorio-de-esta-skill>/references/por-que.md`.

**Cuándo:** antes de entregar un texto a alguien de fuera; al escribir
documentación, una presentación, una propuesta o un correo largo; cuando alguien
dice que un texto "suena a IA".

## Los siete marcadores

Los tres primeros bastan para reconocer un texto generado.

1. **Paralelismo negativo.** «No es X, es Y», «X, no Y», «no se trata de X, sino
   de Y». → Quita la negación y quédate con lo que afirmas: «Un plan sirve para
   que alguien lo pare a tiempo».
2. **Regla de tres.** Tres adjetivos o sintagmas donde el contenido pedía uno o
   dos («claro, sencillo y directo»). → Si el tercero no añade nada, sobra.
3. **Epigrama como titular.** «Lo que toda pieza tiene que cumplir» en vez de
   «Requisitos». → El término estándar del oficio.
4. **Raya larga en exceso**, donde iba una coma, un paréntesis o un punto. → Una
   o dos por documento.
5. **Dos puntos aforísticos** para rematar con una sentencia («El resultado es
   claro: no funciona»). → Punto y seguido, o una sola afirmación.
6. **Vocabulario recurrente:** clave, fundamental, crucial, robusto, sólido,
   potente, riguroso, profundizar, panorama, enfoque, en última instancia, cabe
   destacar, es importante señalar, no solo… sino también, permite (como
   comodín), garantizar, optimizar, impulsar. → El verbo o el sustantivo
   concreto: «permite mejorar la legibilidad» → «se lee mejor».
7. **Grandilocuencia:** conectar algo con un tema mayor o cerrar con una
   reflexión sin dato («Esto es lo que separa un dato de una afirmación»). →
   Bórrala.

## Cómo revisar

```bash
node <directorio-de-esta-skill>/scripts/redaccion.mjs revisar <fichero…>    # cuenta
node <directorio-de-esta-skill>/scripts/redaccion.mjs revisar --texto "…"   # una cadena
node <directorio-de-esta-skill>/scripts/redaccion.mjs detalle <fichero>     # cada caso en su línea
```

El script cuenta y localiza; decidir si cada caso sobra te toca a ti. Solo
puntúan los marcadores 1, 2, 3, 6 y 7; la raya larga y los dos puntos se
informan aparte, porque una expresión regular no distingue un remate de una
explicación.

**Umbral orientativo** para unas 2.000 palabras: cero paralelismos negativos,
menos de tres reglas de tres, ningún titular epigramático.

## Falsos positivos que el script ya excluye

- «clave» como sustantivo (una clave SSH); solo cuenta como adjetivo.
- «lo que hace falta», que contiene «lo que hace».
- Los dos puntos que abren una enumeración.

## Lo que no arregla

El registro: un texto puede pasar los siete y no servir porque usa jerga que su
lector no conoce. Antes de revisar la forma, pregúntate quién lo lee. Y no lo
lleves al extremo: una raya bien puesta o una enumeración de tres cosas reales
son buena escritura.
