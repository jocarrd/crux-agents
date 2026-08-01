---
name: repo-map
description: Levantar en pocos minutos el mapa de un repo que no conoces o que llevas meses sin tocar: por dónde entra la ejecución, qué capas hay, dónde vive cada tipo de cosa, qué convenciones sigue y qué zonas conviene no tocar sin avisar. Usa al volver a un repo dormido, al entrar en uno ajeno, antes de una tarea grande, o cuando la documentación no basta para orientarte.
---

# repo-map

Orientarse antes de tocar. El objetivo no es entender el repo entero: es saber
**dónde mirar** para la tarea que tienes delante.

## Cuándo usar

- Vuelves a un repo que no tocas hace meses.
- Entras en uno que no has escrito tú.
- Vas a acometer un cambio que cruza varias capas.

## Cuándo no usar

- Ya tienes documentación del repo y la tarea es pequeña: léela y ya.
- La tarea toca un fichero que ya conoces.

Si el proyecto sigue el estándar, **empieza siempre por su documentación**
(`repos/<repo>/`). Esto es para cuando esa documentación no existe, se ha
quedado corta, o quieres verificarla contra la realidad.

## El recorrido, en este orden

**1. Por dónde entra la ejecución.** Los puntos de entrada dicen más que
cualquier README: el arranque del servidor, el enrutado, los comandos, las
tareas programadas, los consumidores de cola. Todo lo demás cuelga de ahí.

**2. Cómo se levanta y cómo se prueba.** Los scripts declarados y la
configuración de contenedores. Esto responde a la pregunta práctica: qué tengo
que tener corriendo para ver algo.

**3. La forma del árbol.** Qué carpetas de primer nivel hay y qué significa
cada una. Aquí se ve si el proyecto sigue una arquitectura por capas, por
dominios o ninguna.

**4. Dónde está el dominio.** El código que contiene las reglas de negocio, no
el que habla con el mundo. Suele ser la parte más pequeña y la más importante:
si tienes que entender solo una cosa, es esta.

**5. Las fronteras.** Qué se llama por HTTP, qué comparte base de datos, qué
depende de servicios externos. Las fronteras son donde viven los bugs
interesantes y donde un cambio se propaga a otros repos.

**6. Las convenciones reales.** No las declaradas: las que se ven. Cómo se
nombran los ficheros, cómo se gestionan los errores, cómo se inyectan las
dependencias, dónde van los tests. Un cambio que las respete pasa
desapercibido; uno que no, molesta a todo el mundo.

**7. Las zonas sensibles.** Lo que un cambio despistado rompe caro: migraciones,
autenticación, contratos públicos, generación de artefactos, cualquier cosa con
estado persistente. Merece la pena saber cuáles son antes de tocar, no después.

## Señales que conviene mirar en el historial

- **Los ficheros que más cambian** suelen ser el corazón del repo, o su punto
  de dolor.
- **Los que no cambia nadie desde hace años** son o muy estables o código
  muerto. Comprobar cuál de las dos cosas antes de fiarse.
- **El tamaño de los commits recientes** dice cómo trabaja quien lo mantiene.

## Qué producir

Un resumen corto, no un tratado. Como máximo una página:

- Qué hace el repo, en una línea.
- Puntos de entrada, con su ruta.
- Las tres o cuatro carpetas que importan y qué vive en cada una.
- Cómo se levanta en local.
- Fronteras hacia fuera.
- Zonas sensibles.
- **Lo que no has entendido**, dicho explícitamente.

Ese último punto es el que más valor tiene y el que siempre se omite. Un mapa
que finge cubrirlo todo es peor que uno que señala sus huecos.

## Después

Si el repo pertenece a un proyecto bajo el estándar y esta información no
estaba escrita, **escríbela**: `repos/<repo>/README.md` o el fichero temático
que corresponda. Haber hecho el trabajo dos veces por no anotarlo la primera es
exactamente lo que el estándar viene a evitar.

## Anti-patterns

- **Leer el código en orden alfabético.** Se sigue la ejecución, no el listado.
- **Fiarse de la documentación sin verificar una sola cosa.** Un contraste
  rápido con el código revela si está viva o momificada.
- **Producir un mapa exhaustivo.** Nadie lo lee, incluido tú dentro de un mes.

## Relacionado

- `/promote-to-docs` — para que el mapa sobreviva a la sesión
- `/root-cause` — cuando el objetivo no es orientarse, sino encontrar un fallo
