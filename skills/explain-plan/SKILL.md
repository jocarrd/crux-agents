---
name: explain-plan
description: Presentar una propuesta técnica para que se pueda decidir sobre ella: qué cambia, qué se comprobó para llegar ahí, qué se rompe si es un error, qué alternativas se descartaron y qué queda sin resolver. Incluye cuándo usar tabla, cuándo diagrama y cuándo prosa. Usa antes de implementar algo que no es trivial, cuando haya varias formas razonables de hacerlo, o cuando quien decide no es quien va a escribir el código.
---

# explain-plan

Un plan se escribe **para que alguien pueda pararlo a tiempo**: se mide por lo
que tarda quien lo lee en ver que está mal. El porqué de cada sección:
`<directorio-de-esta-skill>/references/por-que.md`.

**Usar** antes de implementar algo que toca más de un módulo o que no se
deshace en cinco minutos, cuando hay varias formas razonables, o cuando decide
alguien que no escribe el código. **No usar** en cambios acotados y evidentes,
ni con el trabajo ya hecho (entonces `/adr`).

## Las cinco secciones

Ninguna por costumbre: si una no aporta, se quita.

1. **Qué cambia.** Una frase y el alcance real: qué se toca y qué queda fuera.
   Va arriba porque es lo primero que se discute.
2. **Por qué así: la traza.** No la conclusión, sino **qué comprobaste para
   llegar a ella**: qué miraste, qué encontraste, qué descartó el camino obvio.
   Escribe "comprobé X y resultó Y".
3. **Qué se rompe si me equivoco.** El reverso y su coste. Si se deshace con un
   `git revert`, dilo; si implica migrar datos, dilo más alto.
4. **Alternativas descartadas, con el motivo.** "Se descartó X" no sirve; "se
   descartó X porque obliga a mantener dos formatos en paralelo" sí.
5. **Lo que no sé.** Las preguntas abiertas, explícitas.

## La forma

| Contenido | Forma |
| --------- | ----- |
| Comparar opciones | Tabla |
| Flujo con varios actores o pasos | Diagrama de secuencia |
| Dependencias entre piezas | Grafo |
| Estados y transiciones | Diagrama de estados |
| El porqué, los tradeoffs, los riesgos | Prosa |
| Cifras y medidas | En el texto |

Dibuja solo lo que no se ve leyendo.

## Dónde se queda

Aprobado, va al registro de la tarea: `crux task plan <fichero>` lo guarda y la
marca como planificada; los pasos que salgan, con `crux task add`.

## Se cierra cuando se ejecuta

Al terminar, el plan recibe una cabecera de estado: qué está hecho, con qué
commit y, sobre todo, **qué salió distinto de lo planeado y por qué**. Un plan
que sigue describiendo como pendiente algo hecho miente como una documentación
desactualizada. Cerrar no es archivar: se queda como el porqué.

## Anti-patterns

- El diagrama decorativo de cuatro cajas obvias.
- El plan que es una lista de pasos sin porqué: no se puede rechazar.
- La plantilla completa por costumbre.
- Detalle de implementación: nombres de variable y firmas van en el código.
- Presentar solo la conclusión, sin la traza.
- El plan huérfano, que nadie cierra.

## Relacionado

- `/adr` — registrar lo ya decidido
- `/ship` — la puerta que revisa la implementación del plan
