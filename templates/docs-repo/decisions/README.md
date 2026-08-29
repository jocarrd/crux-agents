# Decisiones (ADRs) — convención y formato

Esta carpeta contiene el **registro cross-repo** (`index.md`). Cada repo tiene
además su propio registro en `repos/<repo>/decisions.md` cuando aplica.

## ¿Dónde va un ADR nuevo?

| Si la decisión afecta a… | Va en… |
| ------------------------ | ------ |
| Más de un repo del proyecto | `decisions/index.md` |
| Solo un repo | `repos/<repo>/decisions.md` |

Si dudas, empieza por single-repo. Si más tarde resulta cross-repo, se
promociona (ver abajo).

## Plantilla canónica

Única para ambos niveles, para que un agente no lea dos formatos distintos y
los trate como cosas diferentes.

```markdown
### ADR-NNN: Título

- **Date**: YYYY-MM-DD
- **Status**: uno de los cinco de la tabla de abajo
- **Context**: qué problema o situación lo motiva
- **Decision**: qué decidimos
- **Consequences**: cómo cambia el código, la operación o el despliegue
- **Reversibility**: cómo de caro sería deshacerlo (recomendado siempre: es lo
  que deja decidir con la cabeza fría si merece la pena probar)
- **Related**: refs a otros ADRs o issues (opcional)
```

### Los estados

| Estado | Significa | Referencia |
| ------ | --------- | ---------- |
| `Open` | Hay que decidir y todavía no hay propuesta. `Decision` dice "ninguna" | — |
| `Proposed` | Hay una propuesta sobre la mesa, aún no se aplica | — |
| `Accepted` | Vigente | — |
| `Inherited` | No la tomamos nosotros: venía con el código | — |
| `Superseded by <ref>` | Ya no vale: otra decisión ocupa su lugar | obligatoria, admite varias separadas por coma |
| `Amended by <ref>` | Sigue vigente, pero otra decisión cambió una parte | obligatoria |
| `Deprecated` | Ya no se aplica y nada la reemplaza | — |

Tres de ellos existen porque la alternativa es peor:

`Amended` — una decisión de la que solo cambió una parte no está superada: el
resto sigue mandando, y marcarla como superada hace que alguien la descarte
entera.

`Open` — un problema conocido sin decidir **es** información, y de la más útil:
avisa a quien llega de que ahí hay un hueco y no un descuido. Sin este estado
acaba sin registrar, que es como se repite el mismo debate cada seis meses.

`Inherited` — separa lo que decidimos de lo que nos encontramos. Importa en
cualquier proyecto con código heredado y es obligatorio en el perfil
`client-repo`, donde confundir ambas cosas significa atribuirle al cliente una
decisión nuestra, o al revés.

Sin un estado para cada caso, el matiz termina escrito en prosa dentro del
campo, que es donde ningún lector automático lo encuentra.

Reglas:

- `NNN` es correlativo dentro del registro donde vive: cada `decisions.md`
  empieza en 001.
- **El campo `Status` contiene el estado y sus referencias, nada más.** El
  porqué del cambio va en `Consequences` del ADR nuevo, que es quien lo conoce.
- Las referencias se citan como dice "Cómo citar entre registros": `ADR-014`
  dentro del mismo registro, `decisions/ADR-014` al cruzar.
- `Reversibility` se pone siempre que se pueda: es lo que deja estimar el coste
  de cambiar de opinión más adelante, y sin ese dato la decisión se juzga a
  ciegas. Solo se omite cuando de verdad no aplica.

### Decisiones con fecha de caducidad

Un parche que se acepta sabiendo que hay que retirarlo lleva un campo más:

```markdown
- **Status**: Accepted
- **Sunset**: cuando el CMS asuma los redirects (ver ADR-022)
```

`Sunset` es un campo y no un estado porque las dos cosas son ciertas a la vez:
la decisión está aceptada **y** tiene fecha de retirada. Como estado habría que
elegir una de las dos y se perdería la otra.

## Cómo citar entre registros

La numeración es local a cada registro, así que al cruzar se usa el prefijo del
path:

| Contexto | Cómo citar |
| -------- | ---------- |
| Dentro del mismo registro | `ADR-007` |
| Cruzando registros | `decisions/ADR-013`, `repos/<repo>/ADR-007` |

## Promoción single-repo → cross-repo

Cuando una decisión que empezó afectando a un repo termina afectando a varios:

1. Crear entrada nueva en `decisions/index.md` con el siguiente número
   correlativo, replicando el contenido y ampliando el contexto.
2. Marcar el ADR viejo como `Status: Superseded by decisions/ADR-NNN`.
3. **No borrar el ADR viejo** — la historia importa.
4. Commit: `docs(decisions): promote repos/<repo>/ADR-X to cross-repo as ADR-NNN`.

## Añadir un ADR

- **Cross-repo**: abrir `index.md`, añadir al final con el siguiente número.
  Commit: `docs(decisions): add ADR-NNN <título>`.
- **Single-repo**: abrir o crear `repos/<repo>/decisions.md` con la cabecera
  mínima que remite a este formato, y añadir la entrada.
  Commit: `docs(repos/<repo>): add ADR-NNN <título>`.
