---
name: skill-creator
description: Escribir una skill nueva que se descubra cuando toca, se pueda seguir sin ambigüedad y ocupe poco contexto: comprobar antes que no exista ya, redactar el disparador, repartir entre el procedimiento y sus referencias, decidir si lleva script, colocarla en el kernel o en el proyecto y probarla con escenarios. Usa cuando quieras convertir en procedimiento algo que ya has hecho más de dos veces a mano, cuando una skill no se active cuando debería, o cuando una skill se haya hecho demasiado larga.
---

# skill-creator

Una skill es un procedimiento que un agente encuentra por su descripción y
carga entero en su contexto cada vez que la usa. Por eso tiene que activarse
cuando toca y ocupar lo menos posible. Los ejemplos y el porqué de cada regla
están en `<directorio-de-esta-skill>/references/por-que.md`.

## 1. ¿Hace falta una skill nueva?

- **Solo si lo has hecho a mano más de dos veces** y la tercera tuviste que
  volver a averiguar algo. Una sola vez no da un procedimiento.
- **Antes de crearla, busca si ya existe.** Escribe la frase con la que lo
  pedirías y compruébala contra el catálogo:
  `node <directorio-de-skill-audit>/scripts/probe.mjs "la frase"`.
  Si gana una skill existente, **amplía esa**; no crees otra que compita con
  ella.
- **Una skill, una cosa.** Si hace tres, se activa mal para las tres.

## 2. El disparador

La descripción del frontmatter es lo único que se lee para decidir si
activarla. Dos mitades: **qué hace**, en términos concretos, y **cuándo
usarla**, con las situaciones y las palabras de quien tiene el problema, no de
quien ya sabe la solución.

```yaml
---
name: nombre-en-kebab-case        # igual que el directorio
description: Qué hace. Usa cuando <situación>, cuando <otra>, o cuando <síntoma>.
---
```

## 3. El tamaño

| | Palabras de `SKILL.md` |
| - | - |
| Objetivo | 400 a 800 |
| Máximo | 1.000 (la suite del kernel y `crux doctor` lo comprueban) |

`SKILL.md` lleva **lo que el agente tiene que hacer**: pasos, comandos, reglas,
tablas de decisión, gotchas en una línea y cómo verificar. Lo demás va en
`references/por-que.md` y se abre solo si hace falta: el porqué de cada regla,
la historia de cómo se descubrió, los casos que la originaron, las fuentes y
los ejemplos largos. Cita la referencia al principio con
`<directorio-de-esta-skill>/references/por-que.md`.

Escribe en imperativo y en frases cortas. No narres lo que el comando ya dice
ni expliques lo que cualquier manual cuenta.

## 4. El cuerpo

```markdown
# nombre
Qué resuelve, en una o dos frases, y dónde está la referencia.
Cuándo usar y cuándo no (se repite: no todos los agentes leen el frontmatter).
El procedimiento, por pasos.
Gotchas.
Anti-patterns, en una línea cada uno.
Relacionado.
```

Los gotchas son lo que más vale: lo que no se deduce del camino feliz.

## 5. ¿Lleva script?

Un script para la parte **mecánica y exacta** que se repite igual (un cálculo,
un formato, una comparación). Prosa para el **criterio** (qué mirar y cómo
interpretarlo). Un script que encapsula el criterio se vuelve una caja negra.

## 6. Neutralidad y sitio

- No nombres herramientas de un agente concreto: describe la acción.
- En el kernel no se nombran proyectos: los datos van en un adaptador.
- **Test de la frontera:** tapa los nombres propios. Si el procedimiento sigue
  teniendo sentido, va al kernel y en el proyecto queda un adaptador; si no, es
  del proyecto.
- Un adaptador tiene que ganar la frase con los nombres del proyecto y perder la
  genérica. Compruébalo con las dos frases escritas antes de la descripción:
  `node <directorio-de-skill-audit>/scripts/probe.mjs --adaptador <adaptador> <skill> "<genérica>" "<con nombres>"`.

## 7. Antes de darla por buena

1. **La descripción:** prueba con `probe.mjs` una frase que no salga de la
   propia descripción. Si gana otra skill, o gana por menos del 15 %, no la
   distingue.
2. **El tamaño:** `wc -w SKILL.md` dentro del presupuesto.
3. **Tres escenarios con respuesta conocida.** Escribe tres preguntas cuya
   respuesta correcta sepas (un caso normal, un caso límite y uno que la skill
   deba rechazar). Dáselas a un agente en un contexto limpio, con solo la skill y
   el modelo más pequeño que tengas, y compara. Si estás acortando una skill,
   pásalas también a la versión anterior: **la nueva tiene que responder
   igual**. Si difiere, falta un matiz; añádelo a `SKILL.md`, no a la
   referencia.
4. **Ejecútala** siguiendo lo que dice, no lo que recuerdas.

## Anti-patterns

- Crear una skill que compite con otra existente.
- Descripción genérica ("ayuda con los despliegues").
- Documentar la herramienta en vez del procedimiento.
- Meter la historia y el porqué en `SKILL.md`.
- Escribirla desde la memoria sin ejecutarla ni probarla.
- Dejarla sin mantenimiento: una skill que miente se sigue con confianza.

## Relacionado

- `/skill-audit` — si una skill está en el sitio correcto y si hay que fusionar
- `/promote-to-docs` — para lo que es conocimiento y no procedimiento
