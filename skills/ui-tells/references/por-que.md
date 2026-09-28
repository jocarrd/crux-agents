# Los falsos positivos y de dónde sale

El procedimiento está en `SKILL.md`.

## Los falsos positivos que costó quitar

Los tres falsos positivos que costó quitar, para no reintroducirlos:

**Etiqueta partida.** Comparar la altura del botón con la de su línea marca
todos los enlaces de la navegación, porque el relleno vertical los hace más
altos. Lo único que distingue un texto partido es contar los rectángulos de un
`Range` sobre el nodo de texto.

**Ventana falsa.** Tres círculos en fila es el cromo de una ventana, pero un
marco alrededor de **una captura de verdad** es legítimo y muy común. Solo
cuenta si no hay `img`, `canvas`, `video` ni `picture` dentro.

**Navegación en dos filas.** Agrupar por la coordenada vertical exacta separa
enlaces que están alineados con dos píxeles de diferencia. Dos enlaces están en
filas distintas solo si los separa más de media altura de enlace.

Y una limitación: las hojas de estilo de otro dominio no se pueden leer desde la
página por CORS, así que la comprobación de `100vh` solo ve el CSS propio.


## De dónde sale

Los marcadores están sacados de [taste-skill](https://github.com/Leonxlnx/taste-skill)
(MIT), en concreto de su sección de AI Tells y de su Pre-Flight Check. De su
lista se han cogido solo los que son neutros respecto al estilo: las
prescripciones estéticas de esa skill (tipografías concretas, asimetría por
defecto, prohibir el negro puro) se han dejado fuera a propósito, porque cada
proyecto tiene su lenguaje y el kernel no debe imponer uno.

