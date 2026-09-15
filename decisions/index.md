# Decisiones del kernel

---

### ADR-001: El remoto es una plantilla declarada, no un supuesto

- **Date**: 2026-08-01
- **Status**: Accepted
- **Context**: `crux clone` componía las URLs asumiendo GitHub y exigía `gh`
  para deducir el propietario. Eso ya fallaba con los proyectos existentes: en
  uno de ellos la documentación vive en una cuenta y el código del cliente en
  otra, así que una sola forma de componer la URL no bastaba. Además, dentro
  de un mismo proyecto convivían `https` y `ssh` sin que se notara.
- **Decision**: el contrato declara `remote` con una **plantilla** que lleva
  `{repo}`, más un mapa de **overrides por repo**. La plantilla es el formato
  primario porque es el único que cubre remotos que no siguen la forma
  `owner/repo`. Se admite un atajo `host`+`owner`+`protocol` por comodidad.
  `crux adopt` lo deduce del `origin` de lo que ya esté clonado.
- **Consequences**:
  - El kernel deja de saber de proveedores: vale igual para GitHub, GitLab
    self-hosted, Bitbucket o Azure DevOps.
  - `gh` deja de ser obligatorio para clonar.
  - La creación de repos remotos sigue cubriendo solo GitHub, a propósito:
    adivinar la API de cada proveedor no compensa cuando crear un repo a mano
    son dos clics.
- **Reversibility**: alta. Es un campo en un JSON y dos funciones.
- **Related**: ADR-002

---

### ADR-002: La visibilidad se declara porque no siempre se puede aplicar

- **Date**: 2026-08-01
- **Status**: Accepted
- **Context**: el flag `--visibility` de `crux init` solo tenía efecto cuando
  el repo lo creaba el CLI de GitHub. Con cualquier otro remoto se ignoraba en
  silencio: creías haber pedido privado y no lo controlaba nadie. Un docs repo
  público con documentación interna dentro no es un descuido de configuración,
  es un incidente.
- **Decision**: la visibilidad prevista se declara en el contrato. `init` la
  dice en voz alta cuando no puede aplicarla, y `doctor` consulta la real donde
  hay API para preguntarla. Público con perfil de cliente es error, no aviso.
- **Consequences**: lo que el kernel no puede garantizar, lo declara y lo
  verifica. Donde no hay API para consultarlo, se dice que no se ha comprobado
  en vez de callar.
- **Reversibility**: alta.
- **Related**: ADR-001

---

### ADR-003: El idioma es una propiedad del proyecto

- **Date**: 2026-08-01
- **Status**: Accepted
- **Context**: convivían descripciones de skills en español y en inglés dentro
  del mismo proyecto. La descripción es lo que decide si una skill se activa, y
  debe llevar las palabras con las que aparece el problema: si el trabajo se
  pide en un idioma y la descripción está en otro, la skill existe pero se
  activa peor justo cuando hace falta.
- **Decision**: `crux.json` declara `language`. Descripciones y documentación
  en el idioma del proyecto; nombres, comandos, ramas y commits en inglés;
  términos técnicos sin traducir. `doctor` avisa de la mezcla.
- **Consequences**: un proyecto cuyo código o cuyos interlocutores sean de otro
  idioma lo declara y se escribe entero en ese idioma, en vez de decidirlo
  fichero a fichero.
- **Reversibility**: alta para la regla; traducir lo ya escrito, no.

---

### ADR-004: Los bloques generados ceden el formato al repo

- **Date**: 2026-08-01
- **Status**: Accepted
- **Context**: los punteros de contexto llevan un bloque que genera `crux link`.
  En un repo con formateador automático, el formateador alineaba las tablas y
  `link` las devolvía a su forma en la pasada siguiente: los dos se reescribían
  el fichero indefinidamente, y el ruido aparecía en el `git status` de
  cualquiera que trabajase ahí.
- **Decision**: la comparación del bloque ignora espacios y la longitud de los
  separadores de tabla. El formateador manda en la forma; el kernel, en el
  contenido.
- **Consequences**: un bloque generado puede verse distinto en cada repo según
  su formateador, y da igual. Lo que no puede cambiar es lo que dice.
- **Reversibility**: alta.

---

### ADR-005: El ciclo de trabajo se declara como una secuencia, no como un catálogo

- **Date**: 2026-08-01
- **Status**: Accepted
- **Context**: el kernel tenía las piezas del ciclo —planificar, aislar,
  verificar, cerrar— como skills sueltas, y el contexto de entrada las
  presentaba como una tabla de "qué invocar en cada momento". La medición de
  uso mostró que las dos que sostienen el resto, la puerta de calidad y el
  cierre de sesión, apenas se invocaban. Y en paralelo apareció el problema que
  eso provoca: dos sesiones trabajando sobre el mismo directorio, mezclando
  cambios y peleándose por los mismos ficheros.
- **Decision**: existe una skill `flow` que declara **el ciclo completo y su
  orden**, con el motivo de cada paso y el coste de saltárselo. Los punteros de
  contexto la presentan como la entrada por defecto, y la tabla de momentos
  queda como atajo. `crux workspace finish` cierra el ciclo subiendo la rama y
  abriendo la propuesta.
- **Consequences**:
  - El aislamiento pasa a ser el camino normal y no la excepción, que es lo que
    evita el conflicto entre sesiones simultáneas.
  - Un catálogo no dice en qué orden se usan las cosas; una secuencia sí.
  - Si el uso no sube en las próximas semanas, el problema no era la
    descubribilidad y habrá que buscar otra causa.
  - **Corregido por ADR-006**: la medición que motivó este ADR solo contaba
    invocaciones por nombre, no la ejecución de los scripts de cada skill. El
    problema existía, pero era menor que el número.
- **Reversibility**: alta. Es una skill y un bloque de texto en las plantillas.

### ADR-006: El uso de una skill se mide también por sus scripts

- **Date**: 2026-08-02
- **Status**: Accepted
- **Context**: `crux usage` contaba solo las invocaciones formales de una skill
  por su nombre. Pero quien sigue el procedimiento a mano ejecuta sus scripts
  sin llamarla, y entonces aparece con cero. Medido sobre una sesión real: la
  puerta de calidad figuraba con 2 invocaciones mientras se pasaba en cuatro
  propuestas seguidas, y su clasificador se había ejecutado 28 veces. Cuatro
  skills del kernel —`code-health`, `skill-audit`, `render-loop`,
  `visual-diff`— salían como muertas y se estaban usando.
- **Decision**: el informe cuenta dos señales y **no las suma**: `llamada`, la
  skill invocada por su nombre, y `script`, el rastro de sus scripts en
  comandos. Una skill con rastro de script deja de contarse entre las que nadie
  usa. Se descartan las menciones precedidas de un verbo de lectura, porque
  abrir un fichero no es ejecutarlo.
- **Consequences**:
  - Sumarlas habría mentido igual, solo que al alza: no son la misma unidad, y
    `script` es una cota superior porque incluye las ejecuciones desde tests.
  - **Invalida parcialmente la premisa de ADR-005.** Aquella lectura de "apenas
    se invocan" se hizo con un instrumento que solo veía una de las dos
    señales. La conclusión sobre la descubribilidad sigue siendo razonable, pero
    la magnitud del problema era menor de lo que el número decía.
  - Sigue sin medir adherencia al procedimiento: un agente puede ejecutar el
    script y saltarse la mitad de los pasos. Eso no lo ve ninguna métrica local.
- **Reversibility**: alta. Es una función en `bin/usage.mjs`.

---

### ADR-007: La promoción a documentación se sostiene con una puerta que bloquea, no con un aviso

- **Date**: 2026-09-02
- **Status**: Accepted
- **Context**: `doc-sync.sh` llevaba desde el principio vigilando la disciplina
  de §7, y el 2026-09-02 se comprobó que no vigilaba nada en el caso que
  importa. Una sesión real sobre un proyecto de cliente midió una auditoría de
  accesibilidad entera, descubrió un despliegue fantasma, identificó la
  librería del hero y resolvió dos preguntas abiertas del docs repo. Al cerrar,
  nada de eso estaba en git. El hook se ejecutó y salió con 0 **dos veces**,
  reproducido después: desde el repo de código salía en la comprobación del
  árbol limpio —todo estaba commiteado— y desde el docs repo salía porque
  buscaba `repos/<nombre-del-docs-repo>`, que no existe. Las dos salidas eran
  correctas según su propio diseño; el diseño era el fallo. Vigilaba **ficheros
  tocados que la doc menciona por nombre**, y lo que se pierde no es un fichero:
  es lo que se midió, se decidió o se descubrió y nunca fue un fichero.
- **Decision**: la disciplina pasa a sostenerse en tres piezas de dureza
  decreciente. `doc-sync.sh` se convierte en una **puerta que bloquea el cierre
  con código 2** cuando el proyecto se ha movido, y exige responder qué se
  queda; bloquea **una sola vez por sesión**, con marca en `~/.crux/state/` y
  respetando `stop_hook_active`. `crux doctor` gana una comprobación de deriva
  (`lib/check-doc-drift.mjs`) que compara el último commit de cada repo de
  código con el último de documentación. Y §7 del estándar pasa a decir
  explícitamente que "no hay nada que promocionar" es una respuesta válida pero
  **tiene que ser una respuesta**.
- **Consequences**: cerrar sesión en un proyecto activo cuesta un turno más.
  Es el precio, y es deliberado: el aviso silencioso ya se probó y falló. Lo que
  **no** resuelve: nadie puede medir desde git si lo promocionado es suficiente
  —se puede responder "nada" y cerrar—, así que la puerta garantiza que se
  pregunte, no que se acierte. La comprobación de doctor tampoco distingue un
  refactor invisible de un hallazgo sin documentar; por eso es aviso y no error.
  Efecto lateral útil: la medida de deriva destapó que `crux init` deja un
  fichero sin commitear al crear un proyecto.
- **Reversibility**: alta. Quitar el `exit 2` devuelve el comportamiento de
  aviso; la comprobación de doctor es un bloque numerado más.
- **Related**: `STANDARD.md` §7, `ADR-005`

---

### ADR-008: Un MCP es una capacidad del proyecto y se declara en el contrato

- **Date**: 2026-09-15
- **Status**: Accepted
- **Context**: el kernel no tenía forma de decir que un proyecto usa un servidor
  MCP. La única vía era `claude mcp add`, que escribe en la configuración local
  de la máquina: se pierde al cambiar de equipo y no distingue un proyecto de
  otro, así que lo que hace falta en uno aparece en todos. Antes de decidir se
  midió un servidor real contra su endpoint. Los números: las definiciones de
  sus 15 herramientas ocupan ~4.759 tokens si el cliente las carga enteras, pero
  **~64 si carga solo los nombres**, que es lo que hace por defecto con búsqueda
  de herramientas. En cambio **una sola respuesta suya ocupó ~15.900 tokens, y
  una búsqueda ~38.600**. El coste no está donde parecía: está en usarlo, no en
  tenerlo.
- **Decision**: `crux.json` gana un campo `mcp` opcional donde el proyecto
  declara sus servidores, y `crux mcp` los escribe como `.mcp.json` en los repos
  que correspondan. El fichero va a git por lo mismo que los punteros de
  contexto: clonas el proyecto y la configuración viene con él. El kernel
  **no declara ninguno** —ninguno vale para todos los proyectos— y **no gestiona
  el encendido y apagado**, porque el agente ya lo hace: un `.mcp.json` pide
  aprobación la primera vez y se desactiva por proyecto sin tocar el contrato.
  Reimplementarlo habría sido una segunda verdad sobre lo mismo. El alcance lo
  decide `repos`, y donde el perfil no escribe punteros tampoco se escribe esto.
- **Consequences**:
  - El `.mcp.json` se commitea, así que las credenciales se referencian con
    `${VARIABLE}` y nunca se escriben. `doctor` lo da como **error**, no aviso, y
    `check-secrets` pasa a mirar también los `.mcp.json`: solo miraba `*.md`, y
    un token ahí dentro no lo habría visto nadie.
  - **Lo que hay que mirar antes de declarar un servidor es cuánto devuelve, no
    cuántas herramientas tiene.** Es lo contrario de lo que sugiere la intuición
    y es la parte de esta medición que sobrevive al servidor que la motivó.
  - `crux mcp remove` retira solo lo que declara el contrato. Lo que haya puesto
    alguien a mano se queda, igual que en `crux hooks remove`.
  - **Desviación de lo planeado**: el plan decía que `doctor` comprobaría que los
    servidores responden. No lo hace. `doctor` no abre conexiones en ningún otro
    bloque, y uno que tarde distinto y diga distinto según haya wifi deja de ser
    una verificación. Esa comprobación vive en `crux mcp status`, que se ejecuta
    cuando uno quiere saberlo; `doctor` se queda con la forma y la deriva.
  - No se declara ningún servidor en ningún proyecto con este cambio. El
    mecanismo entra vacío a propósito: se prueba con el primero que haga falta.
  - Solo hay adaptador para un agente. La forma del contrato es independiente
    del cliente —`transport` se traduce a lo que cada uno llame—, pero mientras
    no exista el segundo adaptador eso es una intención, no una demostración.
  - **Lo que encontró la revisión de la propuesta, antes de integrarla**: la
    primera versión leía el nombre del servidor concatenándolo dentro de la
    expresión que `json_get` pasa a `eval`, así que un `crux.json` clonado con un
    nombre que llevara una comilla doble **ejecutaba código con solo pedir
    `crux mcp status`**. De ahí salen tres cosas que ahora son parte de la
    decisión: los nombres se validan con la misma regla que el resto del kernel,
    ningún nombre se interpola nunca en una expresión —van como argumento, donde
    no son código— y el docs repo recibe el fichero siempre, que es lo que
    permite a `doctor` saber dónde *debería* haber uno. La revisión también
    destapó que el doctor firmaba como conforme un `.mcp.json` inexistente o
    manipulado a mano, y que las huellas de credencial se habían copiado en dos
    sitios y ya habían nacido distintas: por ese hueco pasaba una contraseña
    dentro de una `url`. Ahora viven en `lib/credential-prints.mjs` y la
    traducción del formato en `lib/mcp-format.mjs`, que es lo que hace imposible
    que el verificador y el escritor discrepen.
- **Reversibility**: alta. El campo es aditivo: un `crux.json` sin `mcp` se
  comporta igual que antes. Los ficheros nuevos se borran y el bloque de doctor
  es uno numerado más.
- **Related**: `STANDARD.md` §El contrato, `ADR-001`

---

### ADR-009: La activación de una skill se verifica, no se confía

- **Date**: 2026-09-15
- **Status**: Accepted
- **Context**: el sistema verifica todo menos lo que decide si algo llega a
  usarse. `doctor` verifica la estructura, la puerta verifica el cambio, un hook
  verifica el idioma del commit, `usage` mide el uso a posteriori. La
  **activación** —que una descripción gane cuando aparece su problema— era la
  única pieza que se daba por buena. Y ya había fallado de forma medida: `flow`
  salía con cero invocaciones en 31 sesiones (ADR-005), y `usage` da tres skills
  que se siguen a mano sin que nadie las llame.
  Al medirlo apareció algo que nadie había visto: **los pares que más colisionan
  son los que crea el propio mecanismo de promoción**. Se sube el procedimiento
  al kernel y queda un adaptador abajo, pero si el adaptador vuelve a contar el
  método, los dos pujan por la misma frase. El ejemplo canónico del estándar,
  `device-loop` y `demo-co-device`, daba un **empate exacto**; `render-loop` y
  `pdf-visual-iterate` se pisaban 0,49; `oauth-reauthorize` y su adaptador, 0,46.
  Como el catálogo es global, el adaptador de un proyecto compite en todos los
  demás, donde no aplica. Eso empeora justo cuando el sistema tiene éxito: cada
  promoción añade un par, cada proyecto mete sus adaptadores en la puja ajena.
- **Decision**: `skill-audit` gana la señal que le faltaba —mira la secuela de
  una promoción, no solo la oportunidad— y un `probe` que contesta qué skill se
  activaría ante una frase y **por cuánto gana**. Los casos viven en
  `casos/activacion.tsv`, con una regla: una frase sin nombres propios tiene que
  activar el procedimiento del kernel, nunca el adaptador de un proyecto. La
  comprobación de forma de las descripciones sale del bloque 10 de `doctor` a
  `lib/check-skill-description.mjs`, para que la misma vara pase por los dos
  catálogos: antes solo alcanzaba a las skills de proyecto y las 36 del kernel
  no las miraba nadie.
- **Consequences**:
  - `probe` **no predice lo que hará el agente** y no debe leerse así. Puntúa
    solape de vocabulario ponderado. Un empate es señal fiable de que dos
    descripciones no se distinguen; un ganador no garantiza nada. Sirve para
    comparar dos redacciones y para ver si un cambio apagó una skill, que es
    para lo que se escribió.
  - **Se probó lematizar y se descartó con datos.** Dos stemmers —sufijos
    verbales y solo plurales— empeoraron la medida sobre los mismos 24 casos, de
    2 fallos a 3, con `oauth-reauthorize` ganando una frase de cierre de sesión.
    Queda el precio conocido: «merece» y «merecen» cuentan como distintas.
  - Tres descripciones del kernel se corrigieron con la medida delante:
    `crux-doctor` decía «usa antes de cerrar sesión» y le robaba el momento a
    `end-session`, que ya verifica conformidad; `write-tests` no reconocía
    «añadir tests», que es como se pide de verdad; y `flow` **enumeraba los pasos
    de las demás** —«pasar la puerta de calidad, proponer el cambio y cerrar la
    sesión»— así que competía con sus propias piezas siendo la entrada por
    defecto. Los casos del kernel pasaron de 2 fallos a 1.
  - El fallo que queda está anotado a propósito: `end-session` y
    `promote-to-docs` se solapan porque una contiene a la otra. Ajustarlo habría
    sido sobreajustar el catálogo a mis propios casos.
  - Lo que **no** resuelve: que el catálogo global siga creciendo con cada
    proyecto. Esto mide el daño y permite corregirlo escribiendo mejor, pero no
    acota el catálogo. Mover las skills de proyecto a sus repos se descartó
    porque rompe el perfil `client-repo`: en el repo de un cliente no se escribe.
- **Reversibility**: alta. Un script, un fichero de casos y una señal más en un
  informe. Las tres descripciones corregidas son texto.
- **Related**: `ADR-003`, `ADR-005`, `ADR-006`, `STANDARD.md` §Skills
