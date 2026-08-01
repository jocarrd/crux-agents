# Decisiones del kernel

Aquí se registra **por qué** el kernel es como es. Las reglas están en
`STANDARD.md`; el motivo por el que se eligieron, aquí.

No es lo mismo que las decisiones de un proyecto: estas afectan a todos los
proyectos que consumen el kernel, así que cambiarlas tiene un coste que
conviene tener escrito antes de reabrir el debate.

## Formato

El mismo que el estándar impone a los proyectos, para no tener dos:

```markdown
### ADR-NNN: Título

- **Date**: YYYY-MM-DD
- **Status**: Proposed | Accepted | Superseded
- **Context**: qué problema o situación lo motiva
- **Decision**: qué decidimos
- **Consequences**: cómo cambia el kernel y los proyectos que lo consumen
- **Reversibility**: cómo de caro sería deshacerlo
- **Related**: refs a otros ADRs
```

Numeración correlativa. Al superseder, se marca el viejo y no se borra.
