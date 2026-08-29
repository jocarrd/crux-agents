---
name: carry-env
description: Llevarte los ficheros de entorno de un proyecto a otra máquina. Los reúne en una carpeta con el mapa de a dónde va cada uno y el script que los devuelve a su sitio, sin abrirlos y sin que ningún valor pase por el contexto del agente. Usa cuando cambies de ordenador, montes un portátil desde cero, o vayas a reinstalar y necesites recuperar después lo que no está en git.
---

# carry-env

Todo lo que hace falta para trabajar está en git menos una cosa: los ficheros de
entorno. Están ignorados a propósito, así que un `clone` te deja el código
completo y el proyecto sin arrancar.

Esto los reúne en una carpeta que puedes llevarte, y —lo que de verdad importa—
deja escrito **a dónde vuelve cada uno**. Doce ficheros con nombres planos y
ninguna pista de su ruta no valen nada dentro de tres meses, que es justo cuando
se usan.

## Cuándo NO usar esto

**Para compartir secretos con otra persona.** Esto es una copia en claro para ti
mismo entre dos máquinas tuyas. Un secreto que hay que compartir se comparte por
un gestor de contraseñas, y uno que ha pasado por un canal que no controlas se
rota, no se reutiliza.

**Como copia de seguridad de producción.** Los ficheros del servidor viven en el
servidor. Sacarlos de ahí es una decisión distinta, más delicada, y no la
resuelve un `cp`.

## Reunirlos

```bash
<directorio-de-esta-skill>/scripts/collect.sh --project ~/Proyectos/<proyecto>
```

Deja en `~/entornos-<proyecto>` los ficheros, `RESTAURAR.md` con la tabla de
destinos y `restaurar.sh`, que es el camino de vuelta. Carpeta en 0700 y
ficheros en 0600.

**No abre ningún fichero.** Copia con `cp` y reporta nombres y rutas. Si esto lo
ejecuta un agente, ningún valor entra en su contexto ni queda escrito en la
transcripción de la sesión — y un secreto que ha quedado escrito en una
transcripción ya no es un secreto.

### Qué deja fuera, y por qué importa

| Se salta | Motivo |
| -------- | ------ |
| `*-ws-*` | Copias que genera `crux workspace` del repo principal. Son derivadas: restaurarlas encima de las buenas te deja un entorno que parece bien y apunta a otros puertos. |
| `.next/`, `dist/`, `build/`, `out/` | El mismo fichero, copiado por la herramienta de construcción. Restaurar el artefacto no arregla la fuente. |
| `*.example`, `*.sample`, `*.template` | Plantillas sin valores. Ya están en el repo. |

Y lo que no busca siquiera: nada personal y regenerable —claves SSH, sesiones de
CLI, tokens de registro, OAuth—. Eso se genera en cada máquina. Copiarlo es
peor que regenerarlo, porque un token que viaja es un token que ya no sabes por
dónde ha pasado. Esa lista va en el onboarding de máquina del proyecto.

## Devolverlos

En la máquina nueva, con los repos ya clonados (`crux bootstrap`):

```bash
cd ~/entornos-<proyecto>
./restaurar.sh            # dice qué haría
./restaurar.sh --hazlo    # los copia
```

Busca el proyecto en `~/Proyectos/<proyecto>`; si está en otro sitio, se lo pasas
como argumento. **No sobreescribe nunca**: si el destino ya existe lo salta y lo
dice, porque perder un valor que solo estaba ahí es peor que copiar de menos.

Distingue tres finales —`puesto`, `ya existe`, `sin repo clonado`— y el tercero
es el que hay que mirar: significa que ese repo no está, así que o falta clonarlo
o ya no pertenece al proyecto.

## Al terminar

Borra la carpeta. Es lo único de todo el flujo que lleva secretos en claro fuera
de su sitio, y su valor caduca en cuanto has restaurado.

## Relacionado

- `crux bootstrap` — trae los repos; esto trae lo que los repos no llevan
- `operations/machine-onboarding.md` del proyecto — lo personal, que sí se regenera
