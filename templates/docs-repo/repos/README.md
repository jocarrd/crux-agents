# repos/

Documentación específica de cada repo de {{PROJECT}}. Una carpeta por repo,
nombrada igual que el repo en GitHub.

| Carpeta | Repo | Qué hace |
| ------- | ---- | -------- |
| | | |

## Convenciones dentro de cada carpeta

- `README.md` — índice del repo: qué hace, qué docs viven aquí, dónde está el código
- `decisions.md` — decisiones que afectan solo a este repo
- Resto de docs temáticas según haga falta: `architecture.md`, `api.md`,
  `design-system.md`, `notes.md`…

## Reglas de paths

Los paths que aparecen en estas docs son **relativos a la raíz del repo
descrito** y se escriben en backticks, sin enlazar. Cada doc debe incluir esta
línea en su cabecera:

```
> Paths relativos a la raíz de `<repo-name>/`.
```
