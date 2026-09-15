---
name: flow
description: El ciclo completo de una tarea de desarrollo: en qué orden van sus siete pasos, por qué existe cada uno y qué se paga al saltárselo. No los sustituye, los encadena. Usa al recibir cualquier tarea de desarrollo que no sea trivial, especialmente si vas a trabajar en paralelo con otra sesión sobre el mismo repo.
---

# flow

Las skills sueltas no se encadenan solas. Esto es el orden en que se usan, y
**por qué ese orden y no otro**.

## Cuándo aplica

Cualquier tarea de desarrollo que vaya a producir un commit. Es decir, casi
todas.

## Cuándo no aplica

- Preguntas, exploración, leer código sin cambiarlo.
- Cambios de una línea evidentes: una errata, un valor de configuración.
- Emergencia en producción: ahí manda el playbook de incidencias del proyecto,
  y el orden se recupera después.

Si dudas, el coste de aplicarlo es bajo y el de saltárselo se paga en el diff.

---

## El ciclo

### 1. Entender el terreno

Si no conoces el repo o llevas meses sin tocarlo: `/repo-map`. Si el proyecto
sigue el estándar, su documentación va primero — `repos/<repo>/` del docs repo.

**No se empieza a escribir código para averiguar cómo funciona algo.**

### 2. Aislar el espacio

```bash
crux workspace new <nombre-de-la-tarea>
```

**La rama se crea aquí, antes de tocar una sola línea.** Es la misma que al
final se convierte en la propuesta de cambio, así que todo lo que hagas nace ya
separado de lo que esté haciendo cualquier otra sesión.

Esto es lo que evita el problema más caro de trabajar con varios agentes: dos
sesiones sobre el mismo directorio se pisan los ficheros, mezclan sus cambios
en el mismo commit y acaban peleándose por el puerto y por la base de datos.

Con un espacio propio, cada tarea tiene su rama, su worktree y su runtime. Y al
terminar sale como una propuesta que se revisa, no como un montón de cambios
sueltos mezclados con los de otro.

Salta este paso solo si estás seguro de que nadie más está trabajando en ese
repo. El comando avisa si ya hay otro espacio abierto.

### 3. Planificar antes de tocar código

`/explain-plan` para cualquier tarea que no sea evidente.

**El motivo es económico**: un plan que dice "voy a cambiar el formato de la
clave de caché" se rechaza en cinco segundos. El mismo error descubierto
después de escribir el código es un diff que revisar y probablemente revertir.

El plan se aprueba antes de seguir. Si quien decide no eres tú, aquí es donde
se pregunta.

### 4. Desarrollar

Siguiendo lo que el proyecto ya tiene escrito: convenciones de código, de
tests, de commits. Están en su docs repo, no hay que inventarlas.

Dos cosas que se hacen **durante**, no al final:

- **Tests de lo que duele si falla** (`/write-tests`). Escribirlos después es
  escribirlos para que pasen.
- **Si algo se rompe y no sabes por qué**: `/root-cause` antes de proponer un
  arreglo. Cambiar cosas a ver si funciona es lo que convierte un bug en dos.

### 5. La puerta

```
/ship
```

Ocho puertas y cualquiera aborta: tests en verde antes de mirar nada, leer el
diff entero, correctitud, simplificación —después de la correctitud, nunca
antes—, regresión, validación en el entorno real **solo si el cambio se ve
desde fuera**, deriva de la documentación, y commit.

**No se commitea con una puerta en rojo y "ya lo arreglo".** Entonces no es una
puerta, es un adorno.

### 6. Proponer

```bash
crux workspace finish <nombre>
```

Sube la rama y abre la propuesta con el resumen de los commits.

Se niega en dos casos, y los dos a propósito:

- **Si queda algo sin commitear.** Lo que no está en git no llega a la
  revisión, y esa es la razón de trabajar así.
- **Si el commit no ha pasado la puerta.** `/ship` deja constancia de qué
  commit verificó; si no coincide con el actual, hay que volver a pasarla. Así
  **no se abre una propuesta de código que nadie ha revisado**, y la revisión
  deja de depender de que alguien se acuerde.

### 6a. Revisar la propuesta

```
/review-pr
```

Con la propuesta ya abierta y **desde un contexto independiente del que escribió
el cambio**: si el diff hace lo que promete, si el arreglo está completo por
todas las puertas por las que entra el problema, si los tests fallan sin él, y
qué deuda deja.

No repite `/ship`. `/ship` pregunta si está listo lo que hiciste; esto pregunta
si es correcto y completo lo que se propone, y lo pregunta alguien que no
estaba dentro del problema. Es la diferencia entre revisar y confirmar.

### 6b. Fusionar, cuando tú lo autorices

```bash
crux workspace merge <nombre>          # enseña el estado
crux workspace merge <nombre> --yes    # fusiona
```

Mira las comprobaciones automáticas, los conflictos y la revisión, y **no
fusiona sin el flag**. La decisión sigue siendo de una persona; el comando solo
se asegura de que llega informada.

Si el repo no tiene CI, lo dice: "nada lo bloquea" no es lo mismo que "está
verificado".

### 7. Cerrar

```
/end-session
```

Lo que se ha aprendido y no queda en el código —decisiones, gotchas,
convenciones— se escribe donde sobreviva a la sesión. Si no, se pierde, y en
tres meses alguien vuelve a descubrirlo.

**Y se cierra el plan del paso 3.** Cabecera de estado con lo hecho, el commit
de cada paso y qué salió distinto de lo planeado. Ver `/explain-plan`.

---

## El orden importa

| Paso | Si te lo saltas |
| ---- | --------------- |
| Entender | Escribes código para averiguar lo que la documentación ya dice |
| Aislar | Te mezclas con otra sesión y acabas resolviendo conflictos que no existían |
| Planificar | Descubres el error cuando ya es un diff |
| Tests durante | Los escribes para que pasen, no para que fallen |
| La puerta | Entra trabajo roto, y se descubre en producción |
| Proponer | El cambio no se revisa, o se revisa cuando ya está integrado |
| Fusionar | Entra sin mirar si el CI pasó o si hay conflictos |
| Cerrar | Lo aprendido muere con la sesión |

Y dos inversiones que cuestan caro:

- **Simplificar antes de verificar** es tirar el trabajo: puliste código
  incorrecto.
- **Aislar después de empezar** obliga a mover cambios ya hechos entre ramas,
  que es justo el lío que se quería evitar.

## Anti-patterns

- **Encadenar los pasos sin pensar.** Esto es un orden, no un ritual: una
  errata no necesita plan, y una emergencia no necesita espacio aislado.
- **Anunciar el paso en vez de darlo.** Decir "voy a pasar la puerta de
  calidad" y no ejecutarla es peor que no tenerla.
- **Dejar el espacio abierto para siempre.** Un espacio es desechable; si lleva
  semanas vivo, o la tarea era demasiado grande o ya no interesa.

## Relacionado

Cada paso tiene su procedimiento: `/repo-map`, `/workspace`, `/explain-plan`,
`/write-tests`, `/root-cause`, `/ship`, `/end-session`.
