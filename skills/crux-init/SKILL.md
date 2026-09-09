---
name: crux-init
description: Arrancar el repo de documentación de un proyecto nuevo bajo el estándar, o formalizar uno que vive sin documentación. Crea el repo en el remoto, materializa la estructura mínima desde las plantillas del kernel, escribe el contrato crux.json y genera los punteros de los repos de código. Usa cuando empiezas un proyecto o quieres poner bajo el estándar uno que ya existe.
---

# crux-init

Crea el docs repo de un proyecto nuevo siguiendo el estándar.

## Cuándo usar

- Arrancas un proyecto y quieres su documentación montada desde el día uno.
- Tienes un proyecto que vive sin documentación y quieres formalizarlo.

Si el proyecto **ya tiene** un docs repo con contenido, usa `crux adopt`, que
lo registra sin tocar lo que ya hay.

## Precondiciones

- El kernel instalado en esta máquina (`crux version` responde).
- `gh` autenticado, salvo que uses `--no-remote`.

## Flujo

### 1. Recoger los datos

Pregunta al usuario:

1. **Nombre del proyecto**, en kebab-case minúscula. Será también el nombre de
   la carpeta padre, así que conviene que sea corto.
2. **Descripción**, una línea.
3. **Repos que ya existen**, si los hay.
4. **Perfil**: `multi-repo` si el código es propio, `client-repo` si el código
   pertenece a un cliente y no se puede tocar.
5. **Visibilidad** del docs repo: privado por defecto.

El perfil es la decisión que más consecuencias tiene: determina si se escribe
o no en los repos de código, y qué reglas hace cumplir la verificación. Ante
la duda, pregúntalo explícitamente en vez de asumir.

### 2. Ejecutar

```bash
crux init <project> \
  --description "..." \
  --repos "repo-a,repo-b" \
  --profile multi-repo
```

El comando crea el repo en el remoto, lo clona, materializa la estructura
desde las plantillas, escribe `crux.json`, hace el commit inicial y genera los
punteros de los repos que encuentre en disco.

Es determinista: sale de las plantillas del kernel, no de que se reproduzcan
ficheros a mano. Dos ejecuciones dan el mismo árbol.

### 3. Verificar

```bash
crux doctor
```

Debe salir conforme antes de dar el bootstrap por bueno.

### 4. Explicar al usuario qué tiene ahora

- Dónde ha quedado cada cosa y qué carpetas aparecerán después, a demanda:
  `architecture/`, `conventions/`, `operations/` y `topics/<tema>/` solo
  cuando el proyecto las necesite.
- Que los repos de código se colocan como hermanos del docs repo.
- Que para añadir uno nuevo está `/add-repo-to-docs`.

## Errores comunes

- **El repo ya existe en el remoto.** Decidir entre otro nombre o limpiar a
  mano; el comando no borra nada ajeno.
- **El nombre no es kebab-case.** El comando lo rechaza a propósito: media
  convención depende de que la carpeta se llame exactamente como el proyecto.
- **El proyecto ya tenía documentación.** No es este comando; es `crux adopt`.

## Relacionado

- `/add-repo-to-docs` — registrar un repo en un proyecto ya montado
- `/crux-doctor` — verificar conformidad
- `/end-session` — el ritual de cierre que mantiene todo esto vivo
