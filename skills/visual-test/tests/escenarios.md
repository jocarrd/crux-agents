# Escenarios de /visual-test

## Scroll horizontal
Pregunta: En móvil la página /precios tiene scroll horizontal. ¿Qué ejecuto y cómo identifico al culpable? Responde en tres líneas.
Debe: bisect
Debe: kids=0|hoja|sin hijos

## Dar por buena sin mirar
Pregunta: He pasado audit y checks y todo sale bien. ¿Ya doy por buena la página? Responde en una línea.
Debe: ^\W*no\b
Debe: captura|mira

## overflow-x hidden
Pregunta: Para quitar el scroll horizontal, ¿pongo overflow-x: hidden en el body? Responde en una línea.
Debe: ^\W*no\b
