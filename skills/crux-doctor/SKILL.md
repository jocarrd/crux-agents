---
name: crux-doctor
description: Pasar el doctor a un proyecto: verificar que su repo de documentación cumple el estándar —contrato, estructura obligatoria, repos declarados frente a los que hay, reglas del perfil, estado de los ADRs, enlaces markdown, documentos huérfanos y formato de las skills— y dejarlo en conforme. Usa después de migrar o reorganizar documentación, al registrar un repo nuevo, al volver a un proyecto que llevabas tiempo sin tocar, o cuando quieras comprobar si algo se ha desalineado.
---

# crux-doctor

Comprueba la conformidad de un docs repo con el estándar. El estándar sirve de
poco si solo se confía en que se cumple.

## Cuándo usar

- Antes de cerrar una sesión de trabajo con cambios en documentación.
- Después de mover, renombrar o borrar ficheros de documentación.
- Al volver a un proyecto que llevabas meses sin tocar.
- Tras actualizar el kernel, para ver qué proyectos quedaron desfasados.

## Uso

```bash
crux doctor          # sobre el proyecto del directorio actual
crux doctor <dir>    # sobre otro
```

Sale con código 1 si hay errores. Los avisos no bloquean.

## Qué comprueba

1. **El contrato.** Que existe `crux.json`, que tiene los campos obligatorios,
   que el perfil declarado existe y qué versión del kernel se usó.
2. **La estructura obligatoria.** Los ficheros del suelo del estándar, y que
   el puntero de Claude sea un enlace al canónico y no una copia que diverja.
3. **Repos declarados frente a la realidad.** Repos sin carpeta de
   documentación, carpetas sin declarar, repos declarados que no están en
   disco.
4. **Las reglas del perfil.** En un proyecto propio, que cada repo tenga sus
   punteros. En uno de cliente, que **nadie haya escrito** en el repo ajeno:
   eso es error, no aviso.
5. **Los enlaces markdown.** Que todos resuelvan dentro del docs repo.
6. **Las skills del proyecto.** Frontmatter presente y nombre coherente con el
   directorio.

## Cómo interpretar el resultado

**Errores** — rompen el estándar y hay que arreglarlos: contrato ausente,
enlaces rotos, escritura en código ajeno, repo declarado sin documentación.

**Avisos** — el proyecto sigue siendo válido, pero algo se está desalineando:
versión del kernel desfasada, carpeta sin declarar, repo declarado que aún no
está clonado. Merecen una decisión, no necesariamente una acción inmediata.

## Arreglos típicos

| Síntoma | Arreglo |
| ------- | ------- |
| Falta `crux.json` | `crux adopt` |
| Versión desfasada | `crux upgrade` |
| Repo sin puntero | `crux link` |
| Carpeta en `repos/` sin declarar | `/add-repo-to-docs`, o borrarla si sobra |
| Enlace a un fichero de otro repo | convertirlo a texto en backticks |

Un enlace markdown que apunta fuera del docs repo no se arregla corrigiendo la
ruta: se convierte en texto plano. El estándar los prohíbe porque se rompen
con cualquier reorganización y acaban mintiendo, y no hay build que los valide.

## Relacionado

- `/end-session` — el ritual de cierre, que ejecuta esto como uno de sus pasos
- `/crux-init` — crear un proyecto nuevo bajo el estándar
