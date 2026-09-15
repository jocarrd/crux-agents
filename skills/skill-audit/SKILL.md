---
name: skill-audit
description: Revisar si alguna skill de un proyecto es en realidad un patrón que merece subir al kernel, o si alguna del kernel se ha llenado de casos particulares y debería bajar. Inventaría las skills de todos los proyectos, mide su densidad de nombres propios y detecta pares de proyectos distintos que resuelven lo mismo. Usa al crear una skill nueva, y de forma periódica en el cierre de sesión.
---

# skill-audit

Mantiene la frontera entre el kernel y los proyectos. Sin esto, la frontera se
degrada en las dos direcciones: procedimientos valiosos encerrados en un
proyecto, y skills del kernel llenándose de condicionales.

## Dos disparadores

**En caliente, al crear una skill nueva.** Es cuando de verdad se sabe: acabas
de escribirla y tienes fresco qué parte es procedimiento y qué parte son rutas
y credenciales. Una sola pregunta:

> ¿Esto es un patrón o un adaptador?

**En frío, periódicamente.** Enganchado al cierre de sesión cada cierto número
de veces. Una auditoría trimestral que hay que acordarse de lanzar no se lanza
nunca.

## El test

> **Tapa todos los nombres propios de la skill. Si el procedimiento sigue
> teniendo sentido y valor, hay un patrón dentro.**

Se promueve el procedimiento; en el proyecto queda un adaptador corto con
rutas, credenciales y nombres propios.

Con dos guardas:

- **Regla de las dos ocurrencias.** Se promueve cuando dos proyectos lo
  necesitan de verdad, no cuando "podría servir algún día". Excepción
  admisible: valor alto demostrado y acoplamiento casi nulo.
- **Existe el camino inverso.** Si una skill del kernel empieza a acumular
  condicionales por proyecto, no era un patrón: se degrada a `project/`.

## Uso

```bash
node <directorio-de-esta-skill>/scripts/audit.mjs
```

Recorre todos los docs repos adoptados y reporta tres cosas:

**Baja densidad de nombres propios.** Los términos se derivan del `crux.json`
de cada proyecto —su nombre y el de sus repos—, así que no hay lista que
mantener. Una skill larga con pocos nombres propios es sospechosa de contener
un patrón.

**Pares de proyectos distintos que describen lo mismo.** Es la promoción más
obvia y la más invisible, porque nadie ve las dos skills a la vez. Si aparece
un par aquí, la regla de las dos ocurrencias ya está cumplida.

**Las que ya son adaptadores.** Se listan aparte y se excluyen de las
candidatas: un adaptador legítimo también tiene baja densidad, y sin esa
distinción el informe propondría una y otra vez promover lo ya promovido.

**Adaptadores que compiten con el procedimiento que adaptan.** La secuela de
una promoción, que es lo que las tres señales anteriores no veían: miran hacia
delante —qué merece subir— y el par que la propia promoción deja atrás no lo
mira nadie. Arriba el procedimiento, abajo su adaptador, los dos pujando por la
misma frase. Se reporta cuando sus descripciones se pisan por encima de 0,18
—el mismo umbral que los duplicados entre proyectos, y el que recoge el ejemplo
canónico del estándar— o cuando el adaptador **no nombra su proyecto en la
descripción**: la densidad mira el fichero entero, pero al agente solo se le
enseña la descripción.

## Verificar la activación

```bash
node <directorio-de-esta-skill>/scripts/probe.mjs "la frase con la que lo pedirías"
node <directorio-de-esta-skill>/scripts/probe.mjs --casos
```

Todo lo demás del sistema se verifica —la estructura con `doctor`, el cambio
con la puerta, el idioma del commit con un hook—. La activación era lo único
que se confiaba, y es lo que decide si el resto llega a usarse.

`probe` puntúa el solape entre una frase y cada descripción del catálogo
instalado, y dice **por cuánto gana la primera**. El margen es una fracción del
líder, no un valor absoluto, porque la puntuación crece con la longitud de la
frase: por debajo del 15 % es un empate, y cuál gane depende del azar de una
palabra.

`--casos` pasa el fichero `casos/activacion.tsv`, donde cada línea es una frase
real y la skill que debería activarse. La regla que comprueban: **una frase sin
nombres propios tiene que activar el procedimiento del kernel, nunca el
adaptador de un proyecto**. Si gana un adaptador, en los demás proyectos está
ganando algo que allí no aplica.

Sirve para dos cosas concretas: comparar dos redacciones de una descripción, y
ver si un cambio ha apagado una skill que antes se activaba. **No predice lo que
hará el agente**: un empate es señal fiable de que dos descripciones no se
distinguen, pero un ganador no garantiza que gane de verdad.

Al escribir un caso, la frase se escribe **como se pide el trabajo**, con su
registro y sus imprecisiones. Una frase copiada de la descripción siempre pasa
y no prueba nada.

## Cómo leer el resultado

Son **señales, no veredictos**. La densidad no sabe de dominios: una skill
sobre la voz editorial de un producto puede tener pocos nombres propios y aun
así no ser un patrón, porque lo que enseña es específico de ese producto
aunque no lo nombre.

El orden correcto es: el script señala, el test decide, la regla de las dos
ocurrencias frena.

## Cómo se promueve

1. **Separa el procedimiento de los datos.** Lo que queda al tapar los nombres
   propios es lo que sube.
2. **Escribe la skill del kernel** sin mencionar ningún proyecto ni ninguna
   herramienta de un agente concreto.
3. **Reduce la del proyecto a un adaptador** que aporte rutas, credenciales y
   gotchas propios, y que remita el método a la del kernel.
4. **Verifica que la extracción no perdió nada**: ejecuta la skill nueva contra
   el caso real del proyecto de origen y comprueba que da el mismo resultado.
   Una skill genérica que ya no resuelve el caso concreto es peor que la
   específica que había.
5. Reinstala el kernel para que la skill nueva quede disponible.

## Anti-patterns

- **Promover por si acaso.** El kernel inflado es tan malo como el vacío: cada
  skill que no se usa es ruido en el descubrimiento de las que sí.
- **Promover sin dejar adaptador.** Los datos concretos —qué texto es el más
  largo, qué puerto usa el servicio, qué dispositivo es el de referencia— son
  la parte que nadie recuerda a los dos meses.
- **Ignorar el camino inverso.** Una skill del kernel con condicionales por
  proyecto ya no es del kernel.

## Relacionado

- `/end-session` — el cierre de sesión, donde engancha la revisión periódica
- `/promote-to-docs` — el equivalente para la documentación
