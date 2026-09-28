---
name: flow
description: El ciclo completo de una tarea de desarrollo: en qué orden van sus siete pasos, por qué existe cada uno y qué se paga al saltárselo. No los sustituye, los encadena. Usa al recibir cualquier tarea de desarrollo que no sea trivial —tocar código, desarrollar una funcionalidad, arreglar algo, seguir las convenciones del proyecto— y antes de planificar nada, especialmente si vas a trabajar en paralelo con otra sesión sobre el mismo repo.
---

# flow

El orden en que se usan las skills del ciclo. El porqué de cada paso y lo que
cuesta saltárselo están en `<directorio-de-esta-skill>/references/por-que.md`.

**Aplica** a cualquier tarea que vaya a producir un commit. **No aplica** a
preguntas o lectura de código, a cambios de una línea evidentes (una errata, un
valor de configuración) ni a una emergencia en producción, donde manda el
playbook de incidencias y el orden se recupera después. Si dudas, aplícalo.

## 1. Entender el terreno

Si no conoces el repo: `/repo-map`. Si el proyecto sigue el estándar, su
documentación va primero: `repos/<repo>/` del docs repo. No se escribe código
para averiguar cómo funciona algo.

## 2. Aislar el espacio

```bash
crux workspace new <nombre-de-la-tarea>
```

La rama se crea aquí, antes de tocar una línea, con su worktree, sus puertos y
su base de datos. Abre también el registro de la tarea, que se va anotando
mientras se trabaja (`crux task`). Sáltalo solo si estás seguro de que nadie más
trabaja en ese repo; el comando avisa si hay otro espacio abierto.

## 3. Planificar antes de tocar código

- `/grill` si el encargo deja decisiones abiertas.
- `/explain-plan` para cualquier tarea que no sea evidente.

El plan se aprueba antes de seguir; si no decides tú, se pregunta aquí.
Aprobado, se guarda: `crux task plan <fichero>`.

## 4. Desarrollar

Con las convenciones del proyecto, que están en su docs repo. Durante el
desarrollo, no al final:

- Tests de lo que duele si falla: `/write-tests`.
- Si algo se rompe y no sabes por qué: `/root-cause` antes de arreglar.

## 5. La puerta

`/ship`. Ninguna puerta en rojo se deja "para luego".

### 5a. Enseñar lo que se ve

Solo si el diff toca interfaz, después de `/ship` y antes de subir nada:
`/before-after` en escritorio, tablet y móvil, y se espera al sí de quien
decide. Con el sí, `crux visual approve`. Si hay cambios después, se vuelve a
enseñar.

## 6. Proponer

```bash
crux workspace finish <nombre>
crux checks --wait        # en segundo plano
```

`finish` se niega si queda algo sin commitear o si el commit no ha pasado la
puerta. La espera del CI va **en segundo plano**: se dice que está corriendo y
se sigue con otra cosa.

Si el CI sale en rojo: se lee solo el final del log, se arregla en la misma
rama, se pasa `/ship` y se sube. **Tres intentos como máximo**; al tercero, se
para y se cuenta. Una propuesta sin CI no está verificada, y se dice así.

### 6a. Revisar la propuesta

`/review-pr`, desde un contexto distinto del que escribió el cambio. Lanza
solo los especialistas que `crux review` nombra.

### 6b. Fusionar, cuando tú lo autorices

```bash
crux workspace merge <nombre>          # enseña el estado
crux workspace merge <nombre> --yes    # fusiona
```

Sin `--yes` no fusiona. Solo se fusiona sin preguntar si la línea `fusión:` de
la revisión lo permite (solo texto, proyecto propio). Con código o en un repo
de cliente, se pregunta siempre.

### 6c. Vigilar el despliegue

Si lo fusionado se despliega solo: `/deploy-watch`, también en segundo plano.
No se da por publicado hasta verlo. Si falla, se revierte primero y se
investiga después con `/prod-signals` y `/root-cause`.

## 7. Cerrar

`/end-session`: lo aprendido que no queda en el código se escribe donde
sobreviva a la sesión, y se cierra la tarea. Las decisiones anotadas con
`crux task note --why` pasan solas al docs repo al archivarla.

## Anti-patterns

- Encadenar los pasos sin pensar: una errata no necesita plan.
- Anunciar un paso en vez de darlo.
- Simplificar antes de verificar, o aislar después de empezar.
- Dejar un espacio abierto semanas.

## Relacionado

`/repo-map`, `/workspace`, `/grill`, `/explain-plan`, `/write-tests`,
`/root-cause`, `/ship`, `/before-after`, `/review-pr`, `/merge-conflicts`,
`/deploy-watch`, `/prod-signals`, `/end-session`.
