---
name: end-session
description: Ritual de cierre de sesión. Revisa lo que pasó en la conversación y promociona a la documentación lo que merezca sobrevivir (decisiones, gotchas, convenciones, notas). Verifica conformidad y drift. Aplica higiene de memoria del agente. Commit y push de lo pendiente. Usa cuando vayas a cerrar el agente o termines trabajo significativo, o cuando el usuario diga "ya está", "vale", "termina", "cierra sesión".
---

# end-session

Ritual de cierre bajo el estándar. Garantiza que **nada relevante se pierde**
cuando termina la sesión.

## Cuándo usar

- El usuario está terminando una sesión de trabajo significativa.
- Dice algo tipo "ya está", "vale", "perfecto", "cierra sesión", "termina".
- Llevas más de diez turnos de trabajo sin ningún cierre.
- Antes de cambiar de máquina.

## Cuándo no usar

- Sesiones cortas de pregunta y respuesta, sin cambios ni decisiones.
- Cuando el usuario solo pidió información y no hay nada que durabilizar.
- Si ya se ejecutó este ritual en la misma sesión.

## Las cuatro preguntas

Repasa la sesión y pregúntate, por cada categoría, si ha aparecido algo:

**1. Decisiones que no quedan en el código.**
Señales: "hemos decidido X", "elegimos Y", acuerdos sobre arquitectura,
naming o dependencias.
Destino: `<project>-docs/decisions/index.md` si cruza repos;
`<project>-docs/repos/<repo>/decisions.md` si afecta a uno solo.

**2. Gotchas o información operativa.**
Señales: "ojo con X", "esto se rompe si Y", "el header tiene que ser
exactamente Z", problemas con infraestructura o datos externos.
Destino: `<project>-docs/operations/<tema>.md`.

**3. Convenciones o reglas nuevas.**
Señales: "siempre usamos X", "nunca hagas Y", patrones que deberían aplicar
a futuras sesiones.
Destino: `<project>-docs/conventions/<tema>.md`, o el registro del repo si
solo aplica a uno.

**4. Preferencias del usuario sobre cómo trabajar.**
Señales: "prefiero X", "no me gusta Y", correcciones de estilo o de ritmo.
Destino: la memoria local del agente, tipo `user` o `feedback`. Estas se
quedan locales por diseño: son sobre la persona, no sobre el proyecto.

## Flujo

### 1. Inventario de cambios sin commitear

Recorre los repos hermanos del proyecto y reporta los que tengan cambios
pendientes, para no cerrar dejándose trabajo fuera de git.

### 2. Higiene de la memoria del agente

Comprueba si en esta sesión se guardó alguna memoria de tipo `project` o
`reference`. El estándar dice que esas van a git, no a local: promuévelas al
docs repo (con `/promote-to-docs` o directamente) y borra la copia local,
incluida su línea en el índice de memorias.

### 3. Conformidad y drift

```bash
crux doctor
```

Verifica el contrato, la estructura, los repos declarados, las reglas del
perfil y los enlaces markdown. Si aparecen enlaces rotos:

- **A ficheros dentro del docs repo**: arréglalos; la doc referenciada se ha
  movido o renombrado.
- **A ficheros de un repo hermano**: conviértelos a texto plano en backticks.
  El estándar prohíbe enlazar fuera del docs repo porque esos enlaces se
  rompen con cualquier reorganización y terminan mintiendo.

### 4. Frontera de las skills, si tocaste alguna

Si en la sesión se creó o cambió una skill, decídelo ahora en caliente:
¿patrón o adaptador? Es el momento en que se sabe. Cada cierto número de
cierres, pasa además la revisión completa con `/skill-audit`.

### 5. Presentar el balance al usuario

Un resumen estructurado por las cuatro categorías, con lo encontrado en cada
una, y confirmación por cada elemento. Si no hay nada, dilo tal cual: sesión
sin nada que durabilizar.

**El usuario confirma o veta cada elemento.** No se promueve nada
unilateralmente.

### 6. Escribir y commitear

Un commit por categoría, no uno gigante:

- `docs(decisions): ...` para ADRs nuevos
- `docs(operations): ...` para gotchas
- `docs(conventions): ...` para convenciones
- `docs(repos/<repo>): ...` para notas de un repo

Push de cada repo afectado.

### 7. Reporte final

Qué se escribió y dónde, qué se corrigió, qué repos se pushearon. Si queda
trabajo sin commitear a propósito, dilo explícitamente en vez de callarlo.

## Anti-patterns

- **Promover todo lo que se dijo.** El filtro es: ¿le serviría esto a otra
  sesión dentro de seis meses? Si no, no es durable.
- **Promover y no borrar la copia local.** Queda duplicada y divergirá.
- **Saltarse la verificación.** Es el único momento en que se comprueba
  proactivamente que la documentación no miente.
- **Cerrar sin preguntar.** El usuario decide qué sobrevive.

## Relacionado

- `/promote-to-docs` — promover un elemento suelto en mitad de la sesión
- `/skill-audit` — revisar si alguna skill nueva merece subir al kernel
- El estándar completo, en `STANDARD.md` del kernel
