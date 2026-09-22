# Guía de crux, de principio a fin

Esta guía explica el sistema completo, de lo más sencillo a lo más profundo.
No hace falta leerla entera: cada nivel se entiende solo.

Sirve igual a una persona que a un agente. Si eres un agente y vas a **trabajar
en este repo** —añadir una skill, tocar un comando—, lee antes `AGENTS.md`: ahí
están las cuatro reglas que sostienen el kernel y que hay tests vigilando.

- **Nivel 1** — qué es y qué problema resuelve
- **Nivel 2** — instalarlo y el día a día
- **Nivel 3** — crear la documentación de un proyecto nuevo
- **Nivel 4** — adoptar un proyecto que ya existe
- **Nivel 5** — cómo funciona por dentro
- **Nivel 6** — el ciclo de desarrollo
- **Nivel 7** — extenderlo
- **Nivel 8** — mantenerlo

---

## Nivel 1 — Qué es y qué problema resuelve

### El problema

Una persona, varios proyectos, varios repos por proyecto, varias máquinas y
muchas sesiones con agentes distintos. Sin disciplina explícita, el
conocimiento se evapora: queda en la cabeza de alguien, en una conversación
cerrada, en una memoria local que no sobrevive al cambio de portátil, o en un
commit que nadie relee.

Y hay un segundo problema, más sutil: **cada proyecto tiende a inventarse su
propia forma de organizarse**. A los dos proyectos ya no sabes dónde está cada
cosa, y el agente tampoco.

### La solución en una frase

Un repo llamado `crux` que contiene **el estándar, los procedimientos y las
herramientas**, y desde el que se fabrican y mantienen los repos de
documentación de cada proyecto.

### Las tres capas

```
        crux  (kernel: reglas, plantillas, skills, tooling)
          ↑            ↑
    acme-docs    client-docs        ← proyectos, consumidores
          ↑            ↑
     repos código  repo cliente       ← reciben punteros generados
```

Las flechas apuntan **hacia arriba y solo hacia arriba**. El kernel no sabe qué
proyectos existen: hay un test que falla si algún día menciona uno.

| Capa | Qué contiene | Quién la edita |
| ---- | ------------ | -------------- |
| **Kernel** | Estándar, skills transversales, plantillas, comandos | Una vez, para todos |
| **Proyecto** | Documentación del proyecto y sus skills propias | Por proyecto |
| **Repo** | Punteros de contexto | Generados, no se editan |

La regla que sostiene el reparto: **si algo cambia cuando cambias de proyecto,
no es del kernel**.

---

## Nivel 2 — Instalarlo y el día a día

### Instalación, una vez por máquina

```bash
git clone git@github.com:jocarrd/crux.git ~/Proyectos/crux
~/Proyectos/crux/install.sh --remote 'git@github.com:<tu-usuario>/{repo}.git'
```

`--remote` es opcional y fija el remoto habitual de esta máquina, para no
repetirlo en cada proyecto nuevo. Eso hace cuatro cosas:

1. Registra dónde vive el kernel y **cuál es la raíz de proyectos** en
   `~/.crux/config`. La raíz es, por defecto, el directorio donde clonaste el
   kernel: si lo pones en `/opt/dev/crux`, tus proyectos van en `/opt/dev`. El
   instalador lo dice en voz alta, y se cambia con `--projects-dir`.
2. Pone el comando `crux` en `~/.local/bin`.
3. Enlaza las skills para Claude Code y genera los prompts para Codex.
4. Escribe el contexto global de Codex en `~/.codex/AGENTS.md`.

Es idempotente: se puede ejecutar mil veces. Y admite `--dry-run` para ver qué
haría sin tocar nada.

### Los comandos

| Comando | Qué hace |
| ------- | -------- |
| `crux init <proyecto>` | Crea el repo de documentación de un proyecto nuevo |
| `crux clone <proyecto>` | Trae un proyecto entero a una máquina nueva |
| `crux adopt` | Registra un repo de documentación que ya existe |
| `crux add-repo <repo>` | Añade un repo al proyecto |
| `crux link` | Genera y verifica los punteros de los repos de código |
| `crux workspace` | Espacios aislados para trabajar en paralelo |
| `crux hooks` | Engancha el estándar al ciclo, al cierre de sesión y al commit |
| `crux usage` | Mide qué skills se usan de verdad |
| `crux doctor` | Verifica que el proyecto cumple el estándar |
| `crux doctor --machine` | Verifica que la máquina tiene lo que las skills necesitan |
| `crux upgrade` | Alinea el proyecto con la versión actual del kernel |

Todos funcionan desde cualquier subdirectorio del proyecto: suben por el árbol
buscando el `crux.json`, igual que hace git con `.git`.

### El día a día, en cuatro momentos

**Antes de empezar**, si vas a lanzar varias tareas en paralelo sobre el mismo
repo: `/workspace`.

**Antes de commitear**: `/ship`.

**Con la propuesta abierta**: `/review-pr`, desde un contexto que no sea el que
escribió el cambio.

**Antes de cerrar**: `/end-session`.

---

## Nivel 3 — Crear la documentación de un proyecto nuevo

### El comando

```bash
crux init cocina-sencilla \
  --description "Recetas de casa, bien explicadas." \
  --repos "web,api" \
  --profile multi-repo
```

O, en conversación con el agente, `/crux-init`, que pregunta lo que falte.

### Qué ocurre exactamente, paso a paso

**1. Crea la carpeta del proyecto y el repo remoto.**

```
~/Proyectos/cocina-sencilla/
└── cocina-sencilla-docs/     ← creado en GitHub y clonado
```

El repo se llama siempre `<proyecto>-docs`. No es un capricho: media convención
depende de que ese nombre sea predecible.

**2. Materializa la estructura desde las plantillas.**

```
cocina-sencilla-docs/
├── README.md              qué es el proyecto y qué repos lo componen
├── AGENTS.md              el índice canónico para cualquier agente
├── CLAUDE.md              → symlink a AGENTS.md
├── crux.json              el contrato con el kernel
├── .gitignore
├── decisions/
│   ├── README.md          cómo se escribe un ADR
│   └── index.md           el registro de decisiones que cruzan repos
├── repos/
│   ├── README.md          la tabla repo → carpeta
│   ├── web/README.md
│   └── api/README.md
└── .claude/skills/project/   vacío, para las skills propias
```

Sale de `templates/`, con los `{{PLACEHOLDERS}}` sustituidos. **Es
determinista**: dos ejecuciones producen el mismo árbol, y hay un test que lo
comprueba. Antes esto era prosa dentro de una skill que un agente reproducía a
mano, y cada bootstrap salía un poco distinto.

**3. Escribe el contrato.**

```json
{
  "crux": "0.1.0",
  "project": "cocina-sencilla",
  "profile": "multi-repo",
  "repos": ["web", "api"],
  "sections": []
}
```

**4. Hace el commit inicial y lo sube.**

**5. Genera los punteros** de los repos de código que ya estén en disco.

**6. Te dice qué hacer después.**

### Lo que NO crea, y por qué

No crea `architecture/`, `conventions/`, `operations/` ni `topics/`. Esas
carpetas **aparecen cuando el proyecto las necesita**. Un scaffold lleno de
carpetas vacías enseña a ignorarlas; el suelo mínimo obliga a que cada carpeta
que exista signifique algo.

### Dónde va cada documento

Tres preguntas, en este orden:

1. ¿Aplica a **cualquier** proyecto multi-repo? → `architecture/`,
   `conventions/`, `operations/`
2. ¿Solo a este proyecto, pero cruza varios repos suyos? → `topics/<tema>/`
3. ¿Solo a un repo? → `repos/<repo>/`

Así nunca aparece una carpeta suelta en la raíz que parece estándar y no lo es.

### Añadir un repo después

```bash
crux add-repo worker --description "Procesa la cola de imágenes."
```

En un paso: crea `repos/worker/README.md`, lo declara en `crux.json`, añade su
fila a la tabla del índice y genera sus punteros. Antes esto incluía editar a
mano una lista dentro de un script.

---

## Nivel 3b — Cambiar de ordenador

Tres comandos:

```bash
git clone git@github.com:jocarrd/crux.git ~/Proyectos/crux
~/Proyectos/crux/install.sh --remote 'git@github.com:jocarrd/{repo}.git'
crux clone acme
```

`crux clone` trae el docs repo, **lee su contrato** y clona los repos que
declara. Dos cosas salen de ahí y no de un supuesto: la lista de repos —que en
una guía escrita a mano se queda desfasada en cuanto añades uno— y **de dónde
se clona cada uno**.

Después, `crux doctor --machine` dice qué falta en la máquina: herramientas,
autenticaciones, enlaces rotos. Lo que salga como aviso limita qué skills
puedes usar; lo que salga como error, rompe algo.

Las credenciales y secretos de cada proyecto siguen siendo trabajo manual, y
viven en su propia documentación de onboarding.

## Nivel 4 — Adoptar un proyecto que ya existe

Si el proyecto ya tiene documentación, `crux init` no es lo tuyo: es
`crux adopt`, que **no reescribe nada**.

```bash
cd ~/Proyectos/mi-proyecto/mi-proyecto-docs
crux adopt --profile multi-repo
```

Qué hace:

1. Deduce el nombre del proyecto del nombre de la carpeta.
2. Detecta los repos que ya tienen carpeta de documentación.
3. Detecta las secciones opcionales activas.
4. Escribe el `crux.json` que falta.
5. Avisa de los hermanos en disco que aún no están declarados.
6. Lanza `crux doctor` para decirte qué queda por alinear.

Es la puerta de entrada de los proyectos anteriores al kernel.

---

## Nivel 5 — Cómo funciona por dentro

### El contrato: `crux.json`

Es la pieza central. Antes, el script de bootstrap tenía esto escrito dentro:

```bash
REPOS=(Acme acme-engine acme-cms acme-radar demo-co ...)
```

Un script del framework conociendo por su nombre los repos de un proyecto. Por
eso no era reutilizable: para otro proyecto había que editarlo.

Ahora cada proyecto **se declara a sí mismo** y el kernel solo lee. Es el patrón
de un `package.json`: código genérico, datos en el manifiesto. Y el campo
`crux` cumple la función de un lockfile — responde a "¿con qué versión del
estándar se materializó esto?", pregunta que antes no tenía respuesta.

### El remoto: el kernel no sabe de proveedores

El contrato declara **cómo se componen las URLs** de los repos del proyecto:

```json
"remote": {
  "url": "git@github.com:jocarrd/{repo}.git",
  "repos": { "codigo-del-cliente": "https://otro-host.com/su-org/codigo.git" },
  "visibility": "private"
}
```

La plantilla con `{repo}` es el formato primario porque es el único que cubre
remotos que no siguen la forma `owner/repo`. El override por repo no es un caso
raro: **un proyecto puede tener la documentación en tu remoto y el código en el
de otra persona**, que es justo lo que pasa con el perfil de cliente.

`crux adopt` lo deduce del `origin` de lo que ya esté clonado, así que no se
escribe a mano. Y `crux doctor` avisa cuando lo declarado deja de coincidir con
la realidad: esa deriva no molesta en tu máquina y hace fallar el clonado en la
siguiente.

**La visibilidad importa por un motivo concreto**: solo se puede aplicar donde
hay API para crear el repo. En el resto de proveedores lo crea una persona, y
un docs repo público con documentación interna dentro no es un descuido de
configuración, es un incidente. Por eso se declara, `init` la dice en voz alta
cuando no puede aplicarla, y `doctor` comprueba la real donde puede.

### El idioma

También es una propiedad declarada, no una costumbre. La regla: descripciones y
documentación en el idioma del proyecto, nombres e identificadores en inglés,
términos técnicos sin traducir.

Importa porque **la descripción de una skill decide si se activa**, y debe
llevar las palabras con las que aparece el problema. Si el trabajo se pide en un
idioma y la descripción está en otro, la skill existe pero se activa peor justo
cuando hace falta.

### Cómo se encuentra el kernel a sí mismo

En cascada, tres vías:

1. La variable `CRUX_HOME`, si está.
2. `~/.crux/config`, que escribió el instalador.
3. Su propia ruta real, resuelta desde el script en ejecución.

Por eso funciona igual invocado como `crux`, como `bash bin/doctor.sh`, o desde
un test con el `$HOME` redirigido. Cero rutas absolutas escritas a mano.

### Los perfiles: política como dato, no como prosa

Este es el salto conceptual más importante del diseño.

Las reglas de un proyecto de cliente —no tocar su repo, exigir evidencia, no
diagnosticar sin validación— vivían como **párrafos en un README**. Un agente
las lee si las lee, y ningún programa puede comprobarlas.

Ahora son un fichero:

```json
{ "name": "client-repo", "pointers": { "write": false }, "rules": [...] }
```

Y ese `write: false` lo consumen dos programas distintos:

- **`crux link`** lo lee y **no escribe** los punteros: el repo del cliente
  queda literalmente con cero ficheros creados.
- **`crux doctor`** lo lee y **verifica que nadie escribió**: si aparece un
  `AGENTS.md` en el repo ajeno, es error con código de salida 1.

Prevención y detección desde el mismo dato. Eso es convertir una norma en una
garantía.

Perfiles actuales: `multi-repo` (código propio) y `client-repo` (código ajeno).

### Los adaptadores: una fuente, dos agentes

Arquitectura hexagonal, literal. El núcleo es markdown neutro; los adaptadores
traducen a cada agente:

```
skills/<nombre>/SKILL.md          ← la ÚNICA fuente
        │
        ├─ adapters/claude/  → symlink en ~/.claude/skills/<nombre>
        └─ adapters/codex/   → stub en ~/.codex/prompts/<nombre>.md
```

La clave: **el stub de Codex no copia el contenido, apunta al fichero**. Si
copiara, tendrías dos versiones divergiendo — el mismo problema del `cp` que
todo esto viene a eliminar. Editas el `SKILL.md` una vez y los dos agentes ven
el cambio al instante.

De ahí sale una regla dura: **ninguna skill del kernel puede nombrar
herramientas de un agente concreto**. Se describe *la acción*, no *quién la
ejecuta*. Y hay un test que lo vigila.

### Qué pasa cuando ejecutas `crux doctor`

```
bin/crux (dispatcher)
  └─ resuelve CRUX_HOME desde su ruta real
  └─ exec bin/doctor.sh
       └─ carga lib/common.sh
       └─ find_docs_repo()        sube el árbol buscando crux.json
       └─ lee el contrato
       └─ carga profiles/<perfil>.json
       └─ siete bloques de comprobación
       └─ exit 0 | 1
```

Los siete bloques: contrato, estructura obligatoria, repos declarados frente a
la realidad, reglas del perfil, secciones declaradas, enlaces markdown y
formato de las skills.

**Errores** rompen el estándar. **Avisos** señalan desalineación que merece una
decisión, no necesariamente una acción.

---

## Nivel 6 — El ciclo de desarrollo

Tres skills sostienen el día a día.

### `/workspace` — antes de empezar

Un worktree de git aísla los ficheros. **El runtime no.** Es la parte que se
olvida y la que hace daño: dos tareas en paralelo sobre el mismo repo siguen
peleándose por el puerto, la base de datos y el `.env`. El conflicto que creías
haber eliminado reaparece como datos corrompidos — peor que un conflicto de
merge, porque es silencioso.

```bash
crux workspace new fix-login
crux workspace list
crux workspace rm fix-login
```

Cada espacio recibe un **slot**: un rango de puertos, una base de datos y un
fichero de entorno derivados. Se configura en el `crux.json` del proyecto:

```json
"workspace": {
  "portBase": 3000,
  "portsPerSlot": 10,
  "envFile": ".env.local",
  "env": {
    "PORT": "{{PORT0}}",
    "ENGINE_PORT": "{{PORT1}}",
    "DATABASE_URL": "postgres://localhost/app_ws{{SLOT}}",
    "REDIS_URL": "redis://localhost:6379/{{SLOT}}"
  }
}
```

Un registro compartido garantiza que dos espacios no cojan el mismo hueco, y
los slots liberados se reutilizan.

**Detalle de diseño**: el worktree se crea como **hermano** del repo
(`<repo>-ws-<nombre>`), no en un directorio aparte. Es deliberado: los punteros
de contexto son rutas relativas (`../<proyecto>-docs/`), y desde fuera del
proyecto dejarían de resolver. El agente que trabajara ahí se quedaría sin
contexto.

Qué aislar, por orden de daño: puertos (falla al arrancar), base de datos (se
corrompe en silencio), fichero de entorno (invalida lo anterior), volúmenes con
estado, recursos externos compartidos (aquí normalmente no puedes: no lances en
paralelo tareas que los toquen).

### `/ship` — antes de commitear

Cadena de puertas donde cualquiera aborta:

```
1. Sanidad      tests en verde ANTES de mirar nada
                (si ya estaban rojos, no es tu diff: dilo y para)
2. Diff         leerlo entero: ¿hace exactamente lo que pretendías?
3. Correctitud  bugs, casos límite, errores no gestionados
4. Calidad      ¿hay forma más simple? — después de 3, nunca antes
5. Regresión    tests otra vez, porque los arreglos rompen cosas
6. Realidad     levantar el entorno, solo si el diff toca superficie observable
7. Doc drift    ¿esto invalida alguna documentación?
8. Commit       conventional commit que explique el porqué
```

La puerta 6 es la cara. Un script clasifica el diff y decide:

```bash
bash ~/.claude/skills/ship/scripts/diff-scope.sh
```

| Lo que toca | Qué validar |
| ----------- | ----------- |
| Interfaz | Verlo, en los viewports que importen |
| API | Llamar a los endpoints, no solo sus tests |
| Datos | Que la migración aplique **y revierta** |
| Dependencias | Que arranque desde cero, no desde tu caché |

Dos decisiones de diseño que deciden si esto se usa o se abandona: **la puerta
6 es condicional** y **hay modo rápido y modo completo**. Si tarda doce minutos
siempre, dejas de invocarlo en dos semanas y la puerta ha fracasado.

El orden 3 antes que 4 tampoco es casual: **simplificar código incorrecto es
tirar el trabajo**.

### Las demás del ciclo

`/write-tests` y `/root-cause` cubren lo que antes no tenía procedimiento:
elegir qué merece un test y depurar sin proponer el arreglo antes de entender
el fallo. `/e2e` pone el criterio por delante de la herramienta —un flujo lo
merece si su rotura te la cuenta un usuario y no un test—. `/code-health` mide
el conjunto, no el diff, que es lo que se erosiona despacio cuando se genera
mucho código. Y `/explain-plan` presenta una propuesta para poder pararla a
tiempo.

### Después de proponer: el CI, el riesgo y producción

Abrir la propuesta no termina el trabajo. Quedan tres huecos en los que, sin
un paso explícito, no mira nadie.

**El CI.** `crux checks --wait` espera a las comprobaciones y, si algo falla,
trae solo el final del log del trabajo que falló, con las pilas de llamadas
recortadas. Se arregla en la rama y se vuelve a subir, tres intentos como
máximo.

**El riesgo.** `crux review` clasifica la propuesta en riesgo bajo, medio o
alto y dice qué revisores especialistas merece: seguridad, datos, rendimiento
o interfaz. Se lanzan solo esos, en paralelo y cada uno en su contexto. Cuesta
entre 20.000 y 50.000 tokens por especialista, y por eso un cambio pequeño o
sin código no lanza ninguno. La misma clasificación dice quién fusiona: sin
código y en proyecto propio puede ir solo; lo demás lo decide una persona.

**Producción.** `/deploy-watch` espera a que la versión nueva llegue y
comprueba las rutas que el proyecto declara en `deploy`. Si algo falla, se
revierte primero. `/prod-signals` lee los logs que el proyecto declara en
`observability` y los resume agrupando los errores repetidos, que es por donde
empieza `/root-cause` cuando el fallo solo ocurre en el servidor.

### `/end-session` — antes de cerrar

Cuatro preguntas sobre la sesión —decisiones, gotchas, convenciones,
preferencias—, cada una con su destino. Luego: higiene de la memoria del
agente, `crux doctor`, revisión de la frontera de las skills, confirmación del
usuario elemento a elemento, commits por categoría y reporte final.

Regla que atraviesa todo: **las memorias de tipo `project` y `reference` van a
git; solo `user` y `feedback` se quedan locales**. Lo primero es del proyecto y
tiene que sobrevivir al cambio de máquina; lo segundo es sobre la persona.

Esa parte ya no depende de que se invoque el ritual. `crux memory` lista lo que
sigue solo en local, y un hook lo recuerda al cerrar sesión. Se midió: el
ritual se invocaba en 2 de 46 sesiones, y mientras tanto había análisis de
proyecto que solo existía en un portátil. Lo que no se dispara solo no se
dispara.

---

## Nivel 7 — Extenderlo

### La frontera entre kernel y proyecto

La regla vieja era "¿le serviría a otro proyecto?", que se responde con
imaginación. La nueva se puede aplicar:

> **Tapa todos los nombres propios de la skill. Si el procedimiento sigue
> teniendo sentido y valor, hay un patrón dentro.**

Se promueve el procedimiento; en el proyecto queda un **adaptador** corto con
rutas, credenciales y nombres propios.

Ejemplo real: `mobile-native-test` describía cómo probar una app en un Android
físico. Tapando los nombres propios quedaba el procedimiento entero —adb,
permisos udev, `screencap`, Fast Refresh, el gotcha de que en algunas capas de
fabricante los toques no llegan a la app—. Eso subió como `device-loop`. Abajo
quedó `demo-co-device`: package, deep-link y dispositivo de referencia.

Dos guardas:

- **Regla de las dos ocurrencias.** Se promueve cuando dos proyectos lo
  necesitan de verdad. Excepción admisible: valor alto demostrado y
  acoplamiento casi nulo.
- **Existe el camino inverso.** Si una skill del kernel acumula condicionales
  por proyecto, no era un patrón: se degrada.

### `/skill-audit`

Automatiza la vigilancia de esa frontera:

```bash
node ~/.claude/skills/skill-audit/scripts/audit.mjs
```

Recorre todos los proyectos adoptados y reporta tres cosas:

- **Baja densidad de nombres propios.** Los términos se derivan del `crux.json`
  de cada proyecto —su nombre y el de sus repos—, así que no hay lista que
  mantener.
- **Pares de proyectos distintos que describen lo mismo.** La promoción más
  obvia y la más invisible: nadie ve las dos skills a la vez.
- **Las que ya son adaptadores**, excluidas de las candidatas.

- **Adaptadores que compiten con el procedimiento que adaptan.** La secuela de
  una promoción. Las tres señales anteriores miran hacia delante —qué merece
  subir—; esta mira lo que la promoción deja atrás.

Son señales, no veredictos. El script señala, el test decide, la regla de las
dos ocurrencias frena.

Dos disparadores: **en caliente** al crear una skill —es cuando de verdad se
sabe— y **en frío** enganchado al cierre de sesión.

### Verificar que una descripción se activa

```bash
node ~/.claude/skills/skill-audit/scripts/probe.mjs "la frase con la que lo pedirías"
node ~/.claude/skills/skill-audit/scripts/probe.mjs --casos
```

Todo lo demás del sistema se verifica. La activación era lo único que se
confiaba, y es lo que decide si el resto llega a usarse.

`probe` dice qué skill ganaría una frase y **por cuánto**. Un margen por debajo
de 0,5 significa que dos descripciones no se distinguen: cuál gane depende del
azar de una palabra. `--casos` pasa un fichero de frases reales con la skill que
debería activarse, y sirve para lo que hace falta de verdad — comparar dos
redacciones y ver si un cambio ha apagado algo que antes se activaba.

Lo que encontró la primera vez que se pasó: el ejemplo canónico de promoción de
esta misma guía, `device-loop` y `demo-co-device`, daba **empate exacto**. Y
`flow`, que es la entrada por defecto, enumeraba en su descripción los pasos de
las demás —«pasar la puerta de calidad, proponer el cambio y cerrar la sesión»—
y por eso competía con sus propias piezas.

No predice lo que hará el agente: puntúa solape de vocabulario. Un empate es
señal fiable; un ganador, no.

### Cómo se promueve una skill, en cinco pasos

1. Separa el procedimiento de los datos: lo que queda al tapar los nombres
   propios es lo que sube.
2. Escribe la skill del kernel sin mencionar proyectos ni herramientas de un
   agente concreto.
3. Reduce la del proyecto a un adaptador que remita el método al kernel.
4. **Verifica que la extracción no perdió nada**: ejecútala contra el caso real
   del proyecto de origen y comprueba que da el mismo resultado. Una skill
   genérica que ya no resuelve el caso concreto es peor que la específica.
5. Reinstala el kernel.

### Versionar el estándar

`VERSION` sigue semver:

- **patch** — redacción, arreglos de scripts sin cambio de contrato
- **minor** — plantillas, skills o comprobaciones nuevas; los proyectos siguen
  siendo válidos
- **major** — cambia la estructura obligatoria o el formato de `crux.json`

Cuando el estándar evoluciona se cambia **aquí primero**, y los proyectos se
alinean con `crux upgrade`. Ningún proyecto inventa su variante.

`crux upgrade` materializa las piezas que falten y actualiza la versión
declarada. **No sobrescribe contenido existente** salvo `--force`: la
documentación es del proyecto, las plantillas solo cubren huecos.

---

## Nivel 8 — Mantenerlo

### La suite del propio kernel

```bash
./test/run.sh            # todos los casos
./test/run.sh doctor     # los que casan con el patrón
```

Cada caso corre en un sandbox aislado con los directorios de agentes
redirigidos: la suite **no toca** `~/.claude`, `~/.codex` ni `~/Proyectos`.

Tres tipos de caso, y el tercero es el interesante:

1. **Funcionales** — init crea la estructura, link es idempotente, upgrade
   actualiza, workspace reparte slots.
2. **De detección** — que `doctor` **falle** cuando debe: contrato ausente,
   enlaces rotos, skill sin frontmatter, escritura en el repo de un cliente.
3. **Estructurales** — que ninguna skill del kernel nombre un proyecto ni se
   ate a un agente.

Los del tercer tipo no prueban comportamiento: **protegen la propiedad
arquitectónica que justifica que este repo exista**. Si dentro de seis meses
alguien mete una skill con rutas de un proyecto concreto, el test se pone rojo.
Es lo que impide que crux vuelva a acoplarse a lo que documenta, que es
exactamente cómo nació el problema la primera vez.

Ese test ya encontró suciedad real tres veces mientras se construía el kernel.

### Que el estándar se cumpla solo

```bash
crux hooks install    # desde el docs repo del proyecto
crux hooks status
```

Instala cinco cosas: un aviso de deriva de documentación al cerrar sesión, un
aviso de las memorias de proyecto que siguen solo en local, un `pre-commit` que
**bloquea el commit si `doctor` no pasa**, un `commit-msg` que rechaza los
mensajes en español, y un recordatorio del ciclo al empezar a trabajar sobre la
rama principal. Un estándar que hay que acordarse de comprobar se comprueba a
veces.

Para probar un hook antes de un release, instálalo desde el espacio de trabajo
del kernel donde lo estás cambiando: los ajustes apuntan a ese espacio. Al
cerrarlo con `crux workspace rm`, los hooks vuelven solos al checkout principal
y se retiran los que solo existían en el espacio.

El del idioma es el ejemplo más claro de por qué hace falta un hook y no una
línea en un documento: la regla estaba escrita desde el primer commit y **los
27 mensajes del historial del kernel estaban en español**. El `commit-msg` va a
los repos de código además del docs repo, porque ahí es donde se commitea más
— salvo con perfil `client-repo`, donde no se toca nada del cliente, tampoco
sus hooks.

El del ciclo existe por una medición incómoda: la skill que lo describe estaba
escrita, instalada y con su descripción, y `crux usage` la daba con **cero
invocaciones en 31 sesiones**. Una descripción compite por atención con otras
cuarenta; un hook llega solo. Se dispara por **estado** —dónde estás y en qué
rama—, nunca por lo que diga el prompt: adivinar la intención por palabras
acaba avisando cuando no toca y callando cuando sí. Y habla una vez por sesión,
porque el ruido se aprende a ignorar antes que a obedecer.

Avisa en **cualquier repo que viva bajo tu raíz de proyectos**, esté dado de
alta o no (ADR-014). Antes pedía además el layout de proyecto con su docs repo
al lado, y los repos sueltos de la raíz quedaban fuera justo cuando nadie los
vigilaba. Lo que viva ahí sin ser tuyo se excluye con `CRUX_UNMANAGED`.

Un hook que apunta a un fichero inexistente no falla: no hace nada. Y eso es
peor, porque el sistema parece vigilado y no lo está. Por eso `doctor --machine`
lo trata como error.

### Saber si esto sirve

```bash
crux usage --days=90
```

Mide qué skills se usan de verdad contra el catálogo instalado, y separa las
que nunca se usan. No es una lista de borrado: una skill de incidencias sin usar
es una buena noticia. Lo que hay que mirar es la que existe hace meses, cubre
algo frecuente y aun así nadie invoca — casi siempre es que su descripción no se
activa cuando debería.

Cuenta **dos señales, y no las suma**:

| Columna | Qué es |
| ------- | ------ |
| `llamada` | La skill invocada por su nombre |
| `script` | Rastro de sus scripts en comandos: el procedimiento seguido a mano |

La segunda existe porque la primera mentía. Quien sigue el procedimiento sin
llamar a la skill aparecía con cero: la puerta de calidad figuraba con 2
invocaciones mientras se pasaba en cuatro propuestas seguidas, y **cuatro skills
del kernel salían como muertas estando en uso**. Y no se suman porque no son la
misma unidad — `script` es una cota superior, ya que incluye lo que ejecutan los
tests.

Lo que sigue sin medir: **si el procedimiento se siguió entero**. Ejecutar el
script de la puerta no dice que se pasaran sus ocho puertas. Eso no lo ve
ninguna métrica local, y conviene recordarlo antes de sacar conclusiones.

Distingue **no tener datos** de **no tener uso**, que es la forma fácil de
mentir con esta métrica.

### Qué hacer cuando algo falla

| Síntoma | Causa probable | Arreglo |
| ------- | -------------- | ------- |
| `falta crux.json` | El proyecto no está adoptado | `crux adopt` |
| `materializado con crux X, el kernel es Y` | Estándar desfasado | `crux upgrade` |
| `<repo>/ sin AGENTS.md` | Repo nuevo sin punteros | `crux link` |
| `repos/<x>/ no está declarado` | Carpeta huérfana | `crux add-repo`, o bórrala |
| `enlaces markdown rotos` | Documentación movida | Arreglar, o pasar a backticks |
| `perfil client-repo: ... no debería existir` | Se escribió en código ajeno | Borrar el fichero |
| Una skill no aparece en el agente | Instalación desfasada | `~/Proyectos/crux/install.sh` |
| `crux clone` no sabe de dónde traer algo | Sin `remote` en el contrato | Declararlo, o `crux adopt` para deducirlo |
| Un hook no hace nada, o «failed with non-blocking status» en cada turno | Apunta a un fichero que ya no existe | `crux hooks status` para verlo, `crux hooks install` desde el repo principal |
| Falta una herramienta para una skill | — | `crux doctor --machine` |

### La regla de los enlaces, que sorprende a todo el mundo

Dentro de la documentación **solo se enlazan ficheros del propio repo de
documentación**. Las referencias a código de un repo hermano van en backticks,
como texto, sin enlazar.

Por qué: los enlaces se rompen al mover ficheros y, sin un build que los valide,
terminan mintiendo. Un path en backticks el agente lo resuelve igual y nunca se
rompe. `crux doctor` verifica los que quedan.

---

## Resumen de una página

- **Instalar**: clonar `crux` y ejecutar `install.sh`. Una vez por máquina.
- **Ordenador nuevo**: `install.sh --remote '...'` y `crux clone <proyecto>`.
- **Proyecto nuevo**: `crux init <nombre>`. Determinista, sale de plantillas.
- **Proyecto existente**: `crux adopt`. No reescribe nada.
- **Repo nuevo**: `crux add-repo <nombre>`. Declara, documenta y enlaza.
- **Trabajo en paralelo**: `crux workspace new <tarea>`. Aísla ficheros y
  runtime.
- **Antes de commitear**: `/ship`. Ocho puertas, la cara es condicional.
- **Con la propuesta abierta**: `crux checks --wait` y `/review-pr`. Revisar no
  es confirmar, y los especialistas los decide el diff.
- **Después de fusionar**: `/deploy-watch`. Fusionado no es publicado.
- **Antes de cerrar**: `/end-session`. Lo que deba sobrevivir, a git.
- **Cuando dudes si algo cumple**: `crux doctor`. El estándar se verifica, no se
  confía.
- **Que se cumpla solo**: `crux hooks install` en cada docs repo.
- **Saber si sirve**: `crux usage`.
- **Cuando el estándar mejore**: cambiarlo aquí, y `crux upgrade` en cada
  proyecto.
