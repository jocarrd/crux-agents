# {{PROJECT}}

{{DESCRIPTION}}

## Repos del proyecto

Ver `repos/README.md` para el mapeo completo repo → carpeta de documentación.

Layout en filesystem:

```
~/Proyectos/{{PROJECT}}/
├── <repo-1>/
├── <repo-2>/
└── {{PROJECT}}-docs/        ← este repo
```

## Cómo se usa

Este repo es la documentación transversal del proyecto y el contexto canónico
para cualquier agente. El punto de entrada es `AGENTS.md`.

Sigue el estándar definido en `crux` (ver `crux.json` para la versión y el
perfil aplicados). Comandos útiles desde aquí:

```bash
crux doctor    # verifica que la documentación cumple el estándar
crux link      # regenera los punteros de los repos de código
```
