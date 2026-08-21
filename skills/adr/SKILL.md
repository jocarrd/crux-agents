---
name: adr
description: Registrar un ADR: una decisión técnica en el formato canónico del proyecto, en `decisions/index.md` si cruza repos o en `repos/<repo>/decisions.md` si no, con el contexto que la motivó, sus consecuencias y su coste de reversión. Usa cuando se tome una decisión de arquitectura, se elija entre alternativas, se descarte una opción por un motivo que no es obvio, cuando vayas a tocar un registro de decisiones o marcar uno como superado, y cuando alguien pregunte por qué algo está hecho así.
---

# adr

Una decisión que solo vive en la cabeza de quien la tomó se vuelve a discutir
cada seis meses, o peor: se revierte sin querer.

## Cuándo merece un registro

**Sí:**

- Se eligió entre alternativas reales y la elegida no es la obvia.
- Se descartó algo por un motivo que no se deduce del código.
- Afecta a cómo se van a escribir cosas a partir de ahora.
- Alguien va a preguntar "¿y por qué no hicimos X?".
- Se asumió una deuda a sabiendas.

**No:**

- Detalles de implementación que el código ya explica.
- Preferencias de estilo, que van a las convenciones.
- Decisiones reversibles en cinco minutos y sin consecuencias.

El filtro: **si dentro de un año alguien pudiera deshacerlo por no saber por
qué se hizo, merece un registro.**

## Dónde va

| Alcance | Registro |
| ------- | -------- |
| Afecta a más de un repo | `decisions/index.md` |
| Afecta a un solo repo | `repos/<repo>/decisions.md` |

Ante la duda, **empieza por single-repo**. Promocionarlo después está previsto
en el formato; separar uno cross-repo mal colocado, no.

La numeración es local a cada registro. Para citar entre registros se usa el
prefijo del path: `decisions/ADR-013`, `repos/<repo>/ADR-007`.

## El formato

```markdown
### ADR-NNN: Título en una línea

- **Date**: YYYY-MM-DD
- **Status**: Proposed | Accepted | Superseded
- **Context**: qué problema o situación lo motiva
- **Decision**: qué decidimos
- **Consequences**: cómo cambia el código, la operación o el despliegue
- **Reversibility**: cómo de caro sería deshacerlo
- **Related**: refs a otros ADRs
```

## Cómo escribir cada campo

**Context** es el campo que se hace mal. No describe la solución: describe **la
situación que la hacía necesaria**, con datos si los hay. Quien lo lea dentro
de un año no recuerda el problema, y sin él la decisión parece arbitraria.

Incluye aquí lo que se probó y no funcionó, y las alternativas que se
descartaron con su motivo. Es la parte que evita repetir el trabajo.

**Decision** en pasado y en afirmativo: qué se hace ahora, no qué se propone.

**Consequences** honesto en las dos direcciones. Un ADR que solo lista ventajas
no es una decisión, es una justificación. Lo que se pierde también se escribe.

**Reversibility** es el campo más infravalorado: dice si esto es una puerta de
ida y vuelta o de un solo sentido, y por tanto cuánto había que pensarlo.

## Superseder, no reescribir

Cuando una decisión deja de valer **no se edita ni se borra**: se marca
`Status: Superseded by <ref>` y se escribe una nueva.

El registro es historia, no estado actual. Su valor está justamente en poder
ver que algo se decidió, se probó y se cambió — y por qué.

Para promocionar de single-repo a cross-repo: entrada nueva en el registro
cross-repo, el viejo marcado como superseded, y el viejo se queda donde está.

## Al terminar

Commit propio, con el número y el título:

```
docs(decisions): add ADR-NNN <título>
```

## Anti-patterns

- **Escribirlo después, "cuando haya tiempo".** El contexto se evapora en días.
- **Un ADR por cada cambio.** El registro deja de leerse si está lleno de
  ruido.
- **Redactar en futuro o en condicional.** Un ADR registra lo decidido, no lo
  que se está pensando. Para eso está `Status: Proposed`.
- **Editar uno viejo para que encaje con la realidad de hoy.** Eso destruye el
  único valor del registro.

## Relacionado

- `/promote-to-docs` — para el resto de información que debe sobrevivir
- `/end-session` — donde se detecta que hubo una decisión sin registrar
