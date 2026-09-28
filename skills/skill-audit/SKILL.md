---
name: skill-audit
description: Revisar si alguna skill de un proyecto es en realidad un patrón que merece subir al kernel, o si alguna del kernel se ha llenado de casos particulares y debería bajar. Inventaría las skills de todos los proyectos, mide su densidad de nombres propios y detecta pares de proyectos distintos que resuelven lo mismo. Usa al crear una skill nueva, y de forma periódica en el cierre de sesión.
---

# skill-audit

Mantiene la frontera entre el kernel y los proyectos, y el catálogo corto:
procedimientos encerrados en un proyecto que deberían subir, skills del kernel
llenas de casos particulares que deberían bajar, y skills que compiten por la
misma frase. Los motivos y las mediciones detrás de cada umbral:
`<directorio-de-esta-skill>/references/por-que.md`.

**Cuándo:** al crear una skill (¿patrón o adaptador?) y de forma periódica en el
cierre de sesión.

## El test

> Tapa todos los nombres propios de la skill. Si el procedimiento sigue teniendo
> sentido y valor, hay un patrón dentro.

Se promueve el procedimiento y en el proyecto queda un adaptador con rutas,
credenciales y nombres. Dos guardas:

- **Dos ocurrencias:** se promueve cuando dos proyectos lo necesitan de verdad
  (salvo valor alto demostrado y acoplamiento casi nulo).
- **Camino inverso:** una skill del kernel con condicionales por proyecto baja a
  `project/`.

## Auditar

```bash
node <directorio-de-esta-skill>/scripts/audit.mjs
```

Recorre los docs repos adoptados y reporta:

- **Baja densidad de nombres propios** (derivados del `crux.json` de cada
  proyecto): sospechosas de contener un patrón.
- **Pares de proyectos distintos que describen lo mismo:** la regla de las dos
  ocurrencias ya se cumple.
- **Las que ya son adaptadores**, aparte y fuera de las candidatas.
- **Adaptadores que compiten con su procedimiento:** descripciones que se pisan
  por encima de 0,18, o un adaptador que no nombra su proyecto en la
  descripción.

Son señales, no veredictos: el script señala, el test decide y la regla de las
dos ocurrencias frena. El tamaño lo vigila el verificador de descripciones: una
skill de más de 1.000 palabras se acorta con `/skill-creator`.

## Verificar la activación

```bash
node <directorio-de-esta-skill>/scripts/probe.mjs "la frase con la que lo pedirías"
node <directorio-de-esta-skill>/scripts/probe.mjs --casos
node <directorio-de-esta-skill>/scripts/probe.mjs --adaptador <adaptador> <kernel> "<frase genérica>" "<frase propia>"
```

- `probe` dice qué skill gana una frase y **por cuánto**: por debajo del 15 %
  del líder es un empate.
- `--casos` pasa `casos/activacion.tsv` (frase real → skill esperada). Una frase
  sin nombres propios tiene que activar el kernel, nunca un adaptador.
- `--adaptador`: la frase genérica la gana el kernel y la propia, el adaptador.

Sirve para comparar dos redacciones y para ver si un cambio apagó una skill. No
predice al agente: un empate es fiable, un ganador no garantiza nada. **La frase
se escribe como se pide el trabajo**, no copiada de la descripción.

## Promover

1. Separa el procedimiento de los datos.
2. Escribe la skill del kernel sin proyectos ni herramientas de un agente.
3. Deja en el proyecto un adaptador con rutas, credenciales y gotchas propios
   que remita al kernel.
4. Ejecuta la skill nueva contra el caso real de origen: tiene que dar el mismo
   resultado.
5. Reinstala el kernel.

## Anti-patterns

- Promover por si acaso: el kernel inflado es tan malo como el vacío.
- Promover sin dejar adaptador.
- Ignorar el camino inverso.

## Relacionado

- `/skill-creator` — escribir o acortar una skill
- `/end-session` — donde engancha la revisión periódica
- `/promote-to-docs` — el equivalente para la documentación
