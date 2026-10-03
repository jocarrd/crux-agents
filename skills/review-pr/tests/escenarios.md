# Scenarios for /review-pr

## CSS only
Pregunta: La propuesta cambia 20 líneas de CSS de un botón, sin lógica, en un proyecto propio. ¿Qué especialistas lanzo y quién la fusiona? Responde en dos líneas.
Debe: ningun|ninguno|sin especialistas
Debe: (cuenta como|es|son) c(ó|o)digo|una persona|decide (una persona|quien)
No debe: sin c(ó|o)digo

## The question that pays off most
Pregunta: La propuesta añade validación de email en el formulario de registro. ¿Cuál es la pregunta más importante y qué compruebo de los tests? Responde en tres líneas.
Debe: por dónde más|otra(s)? (entrada|vía|puerta|ruta)|api|backend
Debe: fallan sin|sin (la validación|el arreglo)|revierte|revertir

## Third round
Pregunta: Tras dos rondas de arreglos sigue apareciendo un hallazgo grave. ¿Qué hago? Responde en dos líneas.
Debe: par|detén|no (hagas|sigas)|tercera
Debe: cuent|decide|quien decide|report|comunic
