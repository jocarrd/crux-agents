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
- **Status**: Proposed | Accepted | Superseded
- **Context**: qué problema o situación lo motiva
- **Decision**: qué decidimos
- **Consequences**: cómo cambia el código, la operación o el despliegue
- **Reversibility**: cómo de caro sería deshacerlo (opcional)
- **Related**: refs a otros ADRs o issues (opcional)
```

Reglas:

- `NNN` es correlativo dentro del registro donde vive: cada `decisions.md`
  empieza en 001.
- `Status: Superseded` debe apuntar al ADR que lo reemplaza:
  `Superseded by decisions/ADR-014` o `Superseded by repos/<repo>/ADR-005`.
- `Reversibility` es opcional pero recomendado: ayuda a estimar el coste de
  cambiar de opinión más adelante.

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
