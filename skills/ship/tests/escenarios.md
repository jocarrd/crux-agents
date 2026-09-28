# Escenarios de /ship

Cada escenario es una pregunta con respuesta conocida. `crux skill test ship`
los pasa; con `--against <ref>` los compara con otra versión.

## Cambio solo de documentación
Pregunta: He cambiado solo README.md y docs/instalacion.md para corregir dos erratas. Según la skill, ¿qué puertas paso? Responde en dos líneas.
Debe: \b2\b
Debe: \b8\b
Debe: \b9\b

## Endpoint nuevo
Pregunta: He añadido un endpoint POST /api/reservas con su handler y un test unitario. Según la skill, ¿qué puertas aplican y qué hago en la 7? Responde en tres líneas.
Debe: todas|1 a 9|1-9|0 a 9|0-9
Debe: llam|endpoint

## Test existente en rojo
Pregunta: Al arreglar un bug, se ha puesto en rojo el test test_descuento_maximo, que ya existía. Pasa si cambio el valor esperado de 50 a 45. ¿Qué hago? Responde en dos líneas.
Debe: no (lo )?(hagas|edit|cambi|toque|modifi)|no se (edita|cambia|toca)
Debe: par|avis|report|cont|comunic
