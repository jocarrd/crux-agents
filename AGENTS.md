# AGENTS.md — crux

Este repo es el **kernel del sistema de trabajo con agentes**: el estándar, las
skills transversales, las plantillas y el tooling que consumen todos los
proyectos.

No es la documentación de un proyecto. Es lo que los fabrica.

---

## Antes de tocar nada

| Vas a… | Lee |
| ------ | --- |
| Entender el sistema entero | `GUIA.md` — ocho niveles, de lo sencillo a lo profundo |
| Cambiar una regla del estándar | `STANDARD.md` |
| Escribir una skill nueva | La skill `/skill-creator`, y `STANDARD.md` §Skills |
| Tocar un comando | `bin/<comando>.sh`, y la suite en `test/` |

Y ejecuta la suite **antes y después**:

```bash
./test/run.sh
```

---

## Las cinco reglas que sostienen este repo

Están puestas a propósito y hay tests que fallan si se rompen. No son estilo.

### 1. El kernel no nombra ningún proyecto

Ni en las skills, ni en las plantillas, ni en los perfiles, ni en el código. Si
necesitas un dato concreto —una ruta, un puerto, un dispositivo, una
credencial—, ese dato va en un **adaptador** dentro del proyecto, y aquí queda
el procedimiento.

Lo vigila `test_el_kernel_no_nombra_proyectos_concretos`. Es la regla que
impide que crux vuelva a acoplarse a lo que documenta, que es exactamente cómo
nació el problema que este repo resuelve.

### 2. Ninguna skill se ata a un agente concreto

Se describe **la acción a realizar**, no quién la ejecuta ni con qué
herramienta. Es lo que permite que el mismo `SKILL.md` sirva a varios agentes
desde una sola fuente.

Lo vigila `test_ninguna_skill_del_kernel_nombra_herramientas_de_un_agente`.

### 3. Una librería no fija las opciones del shell

`lib/common.sh` **no lleva `set -e`**. Quien la carga ya declaró las suyas, y
pisárselas mata el script en silencio en el primer comando que devuelve algo
distinto de cero.

Esto ya rompió la suite de tests y después `doctor`, las dos veces sin ningún
mensaje. Si un comando devuelve códigos con significado, se recoge con
`cmd || rc=$?`, nunca con `$?` a secas.

Lo vigila `test_la_libreria_no_pisa_las_opciones_del_shell`.

### 4. Lo que se genera, se genera; no se mantiene a mano

Los punteros de los repos, el catálogo de skills del índice y las filas de las
tablas se producen desde plantillas y contratos. Si te encuentras editando algo
que un comando podría escribir, el arreglo es el comando, no el fichero.

### 5. Lo que no se puede leer se dice y se para

Un fichero ausente, ilegible o corrupto **no se convierte en un valor por
defecto**. Se nombra y se detiene ahí.

Seguir con el hueco es lo que produce el peor fallo posible: uno que parece
funcionar. `doctor` leía `?` de un `crux.json` roto y acusaba a campos que sí
estaban; `release` no encontraba consumidores y publicaba diciendo que no había
nada que verificar; `finish` dejaba escapar el error del shell porque el
`2>/dev/null` de un comando no tapa la redirección que hace el propio shell.

`2>/dev/null` vale para preguntar si algo existe. No vale para leer algo que
tiene que estar.

Lo vigila `test_ningun_comando_disimula_un_fichero_que_no_puede_leer`.

---

## Cómo está organizado

```
STANDARD.md    el estándar: qué cumple un proyecto
GUIA.md        cómo funciona todo, de principio a fin
install.sh     instalación por máquina
bin/           un fichero por comando
lib/           utilidades compartidas y verificadores
templates/     lo que se materializa en cada proyecto
profiles/      política verificable: multi-repo, client-repo
adapters/      cómo se expone el kernel a cada agente
skills/        los procedimientos transversales
test/          la suite del propio kernel
```

---

## Añadir algo

**Una skill**: `skills/<nombre>/SKILL.md` con frontmatter `name` y
`description`. La descripción decide si se activa, así que lleva las
situaciones y las palabras con las que aparece el problema. Después,
`./install.sh` para materializarla.

**Un comando**: `bin/<nombre>.sh` más su entrada en el despachador `bin/crux`,
en `README.md` y en la tabla de `STANDARD.md`. Y un caso en `test/cases/`.

**Una comprobación de `doctor`**: dentro de su bloque numerado, con `section` y
`section_ok`. Y un test **en negativo**: que falle cuando debe. Una
comprobación que no se ha visto fallar no sirve.

---

## Cómo se prueba

```bash
./test/run.sh            # todo
./test/run.sh doctor     # los que casan con el patrón
```

Cada caso corre en un sandbox aislado con los directorios de agentes
redirigidos —incluidos los **ajustes** donde viven los hooks, que un caso
devolvió a su sitio real con un `unset` y dejó la máquina con tres hooks
apuntando a un worktree ya borrado—: la suite **no toca** `~/.claude`,
`~/.codex` ni `~/Proyectos`. El runner lo comprueba después de cada caso. Si
escribes un caso que necesite un `$HOME`, **pásalo por invocación**
(`env HOME=... bash ...`), nunca con `export`: exportarlo se lo lleva el caso
siguiente, que al borrarse el sandbox se queda apuntando a un directorio
inexistente. El runner lo detecta y lo reporta como fallo, porque la primera
vez que pasó colgó la suite entera sin un solo mensaje.

Y calibra contra la realidad: cuando `code-health` se escribió, la primera
versión daba 248 hallazgos de ruido en un repo real. Un informe que nadie lee
dos veces no vale, aunque el código sea correcto.

---

## Reglas de trabajo

- **Versionado semver en `VERSION`.** Patch para redacción y arreglos; minor
  para plantillas, skills o comprobaciones nuevas; major si cambia la
  estructura obligatoria o el formato de `crux.json`.
- **El estándar se cambia aquí primero**, y los proyectos se alinean con
  `crux upgrade`. Ningún proyecto inventa su variante.
- **Idioma**: documentación y descripciones en español; nombres, comandos,
  ramas y **commits en inglés**; términos técnicos sin traducir. Lo del commit
  lo comprueba el hook `commit-msg` que instala `crux hooks install`: la regla
  llevaba escrita desde el primer día y el historial estaba entero en español.
- **Conventional commits**, cuerpo de 100 caracteres por línea, sin
  `Co-Authored-By` y sin emojis.
- **Sin comentarios que narren lo que el código ya dice.** Solo el porqué que
  no se deduce leyendo.
