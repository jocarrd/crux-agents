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
  - **Lo que encontró la revisión de la propuesta, antes de integrarla.** Cinco
    cosas que invalidaban partes de esto. La medida tenía un suelo de ruido:
    `log(1 + N/df)` nunca llega a cero, y `cuando` —que está en 33 de las 36
    descripciones del kernel— pesaba 0,74, por encima del propio umbral de
    empate; ahora es `log(N/df)` y `cuando` es palabra vacía. El margen era
    absoluto sobre una escala que crece con la longitud de la frase, así que
    juzgaba igual a una de cinco palabras y a una de doce: pasa a ser una
    fracción del líder. El umbral de colisión, 0,25, **dejaba fuera el ejemplo
    canónico que abre este ADR** —`device-loop` y su adaptador se pisan 0,1887—;
    se iguala a 0,18. La señal de adaptadores que no se nombran acertaba 0 de 4
    sobre el único proyecto real donde disparaba, porque `vcr` tiene tres letras
    y el filtro de términos exigía cuatro. Y el módulo extraído de `doctor` no lo
    usaba `doctor`: la duplicación seguía ahí y las dos copias ya habían
    divergido en el mismo commit que las separaba.
  - **Y una regresión propia**: al quitarle a `flow` la enumeración de los pasos
    ajenos se le quitó también el vocabulario con el que se le pide trabajo, y
    dejó de activarse ante «desarrollar esto siguiendo las convenciones del
    proyecto». No lo medía nadie porque no había ni un caso para `flow`. La
    lección vale más que el arreglo: **tocar una descripción sin un caso que la
    cubra es exactamente lo que este ADR dice que no se debe hacer.**
  - **Corrección posterior, con los adaptadores reales medidos.** El parecido
    entre descripciones señalaba seis adaptadores «compitiendo» y el que fallaba
    era **uno**. Un adaptador habla del mismo trabajo que su procedimiento: que
    compartan vocabulario es inevitable y no prueba nada. Lo que no puede pasar
    es que gane las frases **sin nombres propios**, porque entonces gana también
    en los proyectos donde no aplica. De ahí sale el criterio que faltaba, que es
    simétrico y se comprueba con dos frases: la genérica la gana el kernel, la
    propia la gana el adaptador. Si pierde la primera, sobra método en su
    descripción; si pierde la segunda, faltan nombres propios y no lo encuentra
    nadie. El parecido queda como indicio —qué pares mirar— y la prueba de las
    dos frases como veredicto, que es el orden que esta skill ya declaraba: el
    script señala, el test decide.
- **Reversibility**: alta. Un script, un fichero de casos y una señal más en un
  informe. Las tres descripciones corregidas son texto.
- **Related**: `ADR-003`, `ADR-005`, `ADR-006`, `STANDARD.md` §Skills

---

### ADR-010: El ciclo sigue después de abrir la propuesta, y los especialistas los decide el diff

- **Date**: 2026-09-16
- **Status**: Accepted
- **Context**: el ciclo terminaba en la propuesta revisada y fusionada. Comparado
  con cómo trabajan equipos que ya desarrollan con agentes a escala —revisión
  con varios especialistas en paralelo, el agente arreglando el CI hasta verde,
  despliegue vigilado hasta producción y agentes leyendo las señales de
  producción—, quedaban cuatro huecos en los que no miraba nadie: el CI después
  de abrir la propuesta, la revisión en los ejes que un generalista no ve, la
  producción después de fusionar y los logs cuando algo falla en el servidor.
  Copiar ese modelo entero no tiene sentido a escala de pocas personas: agentes
  vigilando producción las 24 horas, despliegues graduales con feature flags y
  fusión automática según el riesgo presuponen tráfico, equipo e
  infraestructura que aquí no hay.
- **Decision**: cuatro piezas, cada una con su coste acotado.
  1. **Riesgo y especialistas en `/review-pr`.** `review-scope.sh` clasifica el
     diff en riesgo bajo, medio o alto y nombra los especialistas que merece
     (seguridad, datos, rendimiento, interfaz), tres como máximo. Se lanzan
     solo esos, en paralelo y en contextos aislados, con su guía y el diff.
  2. **`crux checks`.** Espera al CI de la propuesta y, si algo falla, trae
     solo el final del log del trabajo, con las pilas de llamadas recortadas.
     `/flow` fija tres intentos de arreglo como máximo.
  3. **`/deploy-watch`.** Después de fusionar, espera a la versión nueva y
     comprueba las rutas que el proyecto declara en `deploy`. Si falla, se
     revierte en git antes de investigar.
  4. **`/prod-signals`.** Lee las fuentes de solo lectura que el proyecto
     declara en `observability` y agrupa los errores repetidos. Se lanza cuando
     hay motivo, no de forma continua.

  La fusión sin preguntar queda limitada a cambios **sin código en proyectos
  propios**. En un repo de cliente decide siempre una persona.
- **Consequences**:
  - **Coste en tokens, medido por pieza.** Un especialista lee el diff, los
    ficheros que toca y su guía (unas 60 líneas), y razona sobre ello: entre
    20.000 y 50.000 tokens por especialista según el tamaño del cambio. Lanzar
    los cuatro en cada propuesta multiplicaba por cinco el coste de revisar, y
    en la mayoría no habría hallazgos: un cambio de estilos no tiene consultas
    ni permisos. Con el reparto por diff, lo habitual es cero especialistas en
    documentación y cambios de 30 líneas o menos (coste igual que antes), uno
    en una pantalla, y dos o tres en un endpoint con sesión o una migración,
    que es donde un fallo no se ve en una captura y donde se pagan solos.
  - `crux checks` no gasta tokens mientras espera: es un bucle de shell. Solo
    entra en el contexto un log recortado cuando algo falla, y el recorte se
    calibró contra un fallo real: el mensaje útil («typescript-eslint does not
    support TS 7.0») quedaba enterrado bajo la pila de llamadas y ahora aparece
    en 14 líneas. Tres intentos acotan el peor caso.
  - `/deploy-watch` devuelve una línea por ruta. Lo caro es mirar la interfaz
    en producción, que es la misma revisión visual que ya se hizo en la vista
    previa.
  - `/prod-signals` mete en el contexto un resumen con tope de grupos por
    fuente —unos pocos miles de tokens—, no el log.
  - `gh pr checks --json` no existe en versiones de gh que siguen en las
    distribuciones, y `gh run view --log-failed` sale vacío en ellas: se lee del
    rollup de la propuesta y el log se pide a la API.
  - El contrato gana dos bloques opcionales, `deploy` y `observability`. Un
    proyecto que no los declara sigue conforme; las skills lo dicen y paran.
  - **Descartado a propósito**: fusión automática de código según el riesgo,
    feature flags, vigilancia continua de producción y un detector propio de
    regresiones de rendimiento. Para lo último, un presupuesto de Lighthouse en
    el `quality.gate` del proyecto da la mayor parte del valor sin tooling nuevo.
- **Reversibility**: alta. Un comando, dos skills y un script nuevos, y texto en
  `/flow` y `/review-pr`. Los bloques del contrato son opcionales.
- **Related**: `ADR-005`, `ADR-009`, `STANDARD.md` §El contrato, §El ciclo de desarrollo

---

### ADR-011: La ceremonia la declara el proyecto; sin contrato, ligera

- **Date**: 2026-09-16
- **Status**: Accepted
- **Context**: con ADR-010 el ciclo creció después de la propuesta, y el
  riesgo se calculaba igual en cualquier repo. Un cambio de 150 líneas en una
  web personal y en un repo de cliente recibían el mismo trato: un especialista
  de 20.000 a 50.000 tokens y fusión con permiso. En lo primero es
  sobreingeniería; en lo segundo, lo justo. El diff no sabe cuánto importa el
  proyecto: lo sabe quien lo da de alta.
- **Decision**: campo opcional `rigor` en `crux.json`, con tres valores.
  `light` reserva los especialistas para el riesgo alto y deja fusionar sin
  preguntar lo que no lo es. `normal` es el comportamiento de ADR-010 y el
  valor por defecto de un proyecto con contrato. `strict` quita el atajo por
  tamaño y no fusiona nunca solo. **Un repo sin `crux.json` es `light`**: si
  no se ha dado de alta, no se ha decidido que sea importante.
- **Consequences**:
  - El riesgo alto (dependencias, sesión, datos, más de 500 líneas) lanza
    especialistas en todos los niveles: bajar la ceremonia no apaga lo que
    rompe en silencio.
  - El perfil `client-repo` sigue mandando sobre la fusión: con cualquier
    rigor, decide una persona.
  - `crux doctor` falla con un valor desconocido, y el clasificador para: una
    errata no puede caer a un nivel por defecto sin avisar.
  - Ningún proyecto existente cambia de comportamiento hasta que declare el
    campo, salvo los repos sin contrato, que pasan a `light`.
- **Reversibility**: alta. Un campo opcional y tres umbrales en un script.
- **Related**: `ADR-010`, `STANDARD.md` §El contrato

---

### ADR-012: El cambio es un objeto con registro, y vive en el estado local

- **Date**: 2026-09-17
- **Status**: Amended by ADR-016
- **Context**: crux tenía el conocimiento del proyecto bien resuelto —el docs
  repo— y el ciclo después de la propuesta, pero no la unidad del medio: la
  tarea. `/explain-plan` decía que el plan "se queda donde está" sin decir
  dónde, y en la práctica vivía en la conversación. Una compactación, un
  reinicio o volver al día siguiente perdían los pasos, lo comprobado y el
  siguiente paso. Otros sistemas lo resuelven con un documento por cambio
  (OpenSpec, el ODD de gentle-ai), pero en el repo de código, que en el de un
  cliente no se puede tocar y que parte en dos una tarea de varios repos. Y la
  medida de uso dice que las instrucciones en prosa no se siguen: `flow` se
  invocó una vez en 46 sesiones; lo que funciona son mecanismos.
- **Decision**: cada espacio de trabajo tiene una tarea, y cada tarea un
  registro en `~/.crux/tasks/<proyecto>/<tarea>.md`: un markdown con cabecera
  —estado, repos, espacios— y secciones fijas —objetivo, alcance, plan, pasos,
  siguiente paso, desviaciones y decisiones, verificación, cierre—. Lo escriben
  los comandos: `workspace new` lo crea (o se une con `--task` desde otro
  repo), `crux task` anota pasos con su evidencia, `ship seal` vuelca el recibo
  y lo marca verificado, `finish` saca de él la descripción de la propuesta y
  `merge` lo marca fusionado. Un hook trae el estado y el siguiente paso al
  retomar un espacio, una vez por sesión.
- **Consequences**:
  - Retomar deja de depender de la conversación: el estado está en disco y
    llega solo.
  - Nada se escribe en los repos: vale igual en el de un cliente, y la
    descripción que sale de la tarea no nombra nuestro tooling.
  - El docs repo sigue siendo lo que dura. Lo que merece sobrevivir a la tarea
    —una decisión, una medida— se promociona al cerrar, como hasta ahora.
  - Un registro local no viaja si se cambia de máquina a mitad de tarea. Es la
    contrapartida aceptada: la alternativa era mezclar estado de trabajo con
    conocimiento.
  - Los estados solo avanzan solos; volver atrás es explícito
    (`crux task status <estado> --force`).
  - Los registros no se acumulan: al cerrar el último espacio de una tarea
    fusionada se archiva en `done/`, fechada, y `workspace gc` borra las
    archivadas de más de 180 días. Una tarea sin terminar nunca se archiva sola.
- **Descartado**: el docs repo (mezcla trabajo con conocimiento, sin
  aislamiento entre sesiones paralelas, y los commits de casillas falsean la
  deriva que mide `doctor`); el repo de código (imposible en un cliente, parte
  las tareas de varios repos); una base de datos aparte (dos fuentes que
  sincronizar); la propuesta como documento vivo (no existe hasta el final).
- **Reversibility**: alta. Un subcomando, un hook y ficheros locales legibles a
  mano; retirarlo no toca ningún repo.
- **Related**: `ADR-010`, `ADR-011`, `STANDARD.md` §La tarea

---

### ADR-013: El registro de espacios se mantiene verdadero sin depender de nadie

- **Date**: 2026-09-17
- **Status**: Accepted
- **Context**: el registro llegó a tener 41 entradas apuntando a carpetas que ya
  no existían, y dos espacios fusionados llevaban más de una semana abiertos.
  Las sesiones liberaban disco con `git worktree remove --force` y
  `git branch -D`, que borran la carpeta y la rama pero no la entrada; `merge`
  dejaba el espacio vivo por defecto; y `gc`, que lo detectaba, solo corría si
  alguien lo pedía. Además, un worktree creado a mano con trabajo pendiente de
  revisión era invisible para crux, y `gc --con-disco` lo habría borrado. La
  regla de cerrar con `crux workspace rm` estaba escrita y no se cumplía.
- **Decision**: mecanismos en lugar de instrucciones.
  - `workspace new`, `list` y `crux status` reparan el registro: retiran las
    entradas sin carpeta **y** sin rama local. Con la rama viva se avisa y no
    se toca.
  - `merge --yes` cierra el espacio al fusionar (`CRUX_MERGE_CLOSE_WORKSPACE`
    pasa a `true`); `rm` sigue negándose si queda algo sin commitear.
  - `crux status` avisa de espacios cuya rama ya no está en el remoto y de
    worktrees que el registro no conoce, con el comando para arreglarlo.
  - `crux workspace adopt <ruta>` registra un worktree hecho a mano, con tarea.
  - Un hook del agente para `git worktree remove` y `rm -r` sobre un espacio
    registrado y propone `crux workspace rm`.
- **Consequences**:
  - Borrar a mano ya no deja basura, y el atajo más habitual se para antes.
  - Una entrada solo se retira sola cuando no queda nada que proteger; si la
    rama existe, decide una persona.
  - `status` mira lo que git ya sabe del remoto, sin red: una rama borrada en
    el remoto se ve cuando alguien hizo `fetch --prune`.
- **Reversibility**: alta. `CRUX_MERGE_CLOSE_WORKSPACE=false` recupera el
  comportamiento de antes; el hook se retira con `crux hooks remove`.
- **Related**: `ADR-012`

---

### ADR-014: Un repo es del sistema por dónde vive, no por tener contrato

- **Date**: 2026-09-18
- **Status**: Accepted
- **Context**: el guarda del ciclo solo avisaba en el kernel, en un docs repo o
  en un repo que colgara de `<raíz>/<proyecto>/<repo>` con su docs repo al
  lado. Eso dejaba fuera a los repos sueltos de la raíz, que en la máquina
  donde se midió son cinco. El 17-09-2026 uno de ellos, `personal-site`,
  recibió dos commits directos a la principal mientras otra sesión fusionaba
  dos propuestas sobre el mismo repo: el push salió rechazado y hubo que
  rebasar. El guarda estaba instalado y funcionando; ejecutado a mano en
  `acme/app` daba el aviso y en ese repo salía vacío.
  Con ADR-011 el estándar ya decía qué hacer sin contrato —tratarlo como
  `light`—, y `review-pr` lo cumplía. El guarda no: para él, ausencia de
  contrato era ausencia de repo.
- **Decision**: separar las dos preguntas que estaban mezcladas. **Si el ciclo
  aplica** se responde por ubicación: cualquier repo bajo la raíz de proyectos
  es del sistema, tenga contrato o no. **Qué ceremonia merece** lo sigue
  respondiendo el contrato, y su ausencia sigue significando `light`.
  `CRUX_UNMANAGED` en la configuración admite rutas o patrones separados por
  `:` para lo que viva bajo la raíz sin ser tuyo, como un clon ajeno.
- **Consequences**:
  - Los repos sueltos reciben el aviso desde el primer prompt, sin darlos de
    alta ni moverlos de sitio.
  - La regla del layout `<raíz>/<proyecto>/<repo>` desaparece del guarda por
    redundante: lo que cubría ya está cubierto por la raíz.
  - Un clon ajeno bajo la raíz recibirá el aviso hasta que se excluya. Es ruido
    en un caso que hoy no se da: los 30 remotos de la raíz son propios.
  - El aviso manda a `/ship`, y `crux ship gate` muere sin `crux.json`. Queda
    pendiente decidir si degrada o si la puerta es solo para proyectos dados de
    alta.
- **Reversibility**: alta. Es una condición en un hook.
- **Related**: `ADR-011`, `ADR-005`, `STANDARD.md` §El rigor

---

### ADR-015: Alternar de máquina es un caso propio, y al llegar no se decide nada

- **Date**: 2026-09-30
- **Status**: Accepted
- **Context**: `bootstrap` monta una máquina vacía y `clone` trae un proyecto
  que no está. Ninguno actualiza lo que ya hay: con el repo en disco dicen "ya
  está" y siguen. Al volver a una torre que llevaba un mes sin usarse, los
  proyectos se habrían quedado con el código de hace un mes y el kernel en la
  0.27, con la 0.59 publicada. En el portátil, a la vez, había trabajo que no
  estaba en ningún remoto: cuatro commits en una principal, dos ramas nunca
  subidas y cambios sin commitear en cuatro repos. Nada lo avisaba al cerrar.
- **Decision**: `crux sync` con dos sentidos.
  - **Al llegar** trae todos los remotos y avanza solo lo que no pide decidir:
    una rama limpia que va por detrás. Si hay cambios sin commitear o las
    ramas se han separado, avisa y no toca. Solo recorre lo que ya está en la
    máquina: los proyectos que no están no se traen, porque cada máquina
    tiene los suyos (`crux clone` para eso). Sí clona un repo que un proyecto
    de aquí declara y falta, y el kernel si hay una versión publicada más
    nueva. La primera versión (0.60.0) traía también los proyectos del remoto
    que no estaban; se quitó en 0.60.1.
  - **Al irse** (`--leave`) falla si algo se quedaría solo en la máquina.
    `end-session` lo ejecuta.
  - Un hook de inicio de sesión hace lo de llegar, como mucho cada diez
    minutos, y solo habla si algo cambió.
  - No viajan las credenciales, que tienen `carry-env`, ni las memorias
    personales del agente (`user` y `feedback`). Se valoró un repo privado
    para ellas y se descartó: son de cada máquina. Las de proyecto ya van al
    docs repo.
- **Consequences**:
  - Abrir sesión en la otra máquina basta para trabajar sobre lo último.
  - El hook cuesta un `fetch` de cada repo en paralelo al abrir sesión. Sin
    red no bloquea: dice qué repos no respondieron.
  - Solo se avanza la rama en la que está cada repo. Las demás ramas locales se
    quedan donde estaban, con su remoto ya traído.
  - La primera vez en una máquina con un kernel anterior hay que instalarlo a
    mano, porque el comando todavía no existe allí.
- **Reversibility**: alta. El hook se retira con `crux hooks remove` y el
  comando no cambia nada que `git` no deje deshacer.
- **Related**: `ADR-013`, skill `carry-env`

---

### ADR-016: Las tareas viajan en una rama aparte del docs repo

- **Date**: 2026-09-30
- **Status**: Accepted
- **Context**: enmienda la consecuencia de ADR-012 que dejaba el registro solo
  en local. ADR-012 separó bien el estado de trabajo del conocimiento, pero
  de ahí sacó que el registro tenía que ser local, y eso mezclaba dos preguntas:
  dónde tiene sentido una cosa y por dónde viaja. Con varias máquinas, una
  tarea empezada en una no existía en la otra. El sistema acabó empujando a lo
  que quería evitar: el estado de trabajo se copiaba a mano en el docs repo
  (una sección "ABIERTO" en unas notas) porque era lo único que viajaba. Al
  medirlo, además, 8 de 14 registros locales seguían en `proposed` con la
  propuesta ya fusionada fuera de `crux merge`.
  Se estudiaron otros sistemas. Gentle AI guardaba la tarea en el árbol del
  producto y la está sacando por árboles sucios y commits accidentales, con
  Engram como transporte; su modo híbrido derivaba porque el agente elegía en
  cada momento qué almacén mandaba. Beads replicó con una rama gestionada por
  worktrees y acumuló fallos (JSONL divergente, hooks que rompían el push, un
  daemon que no traía) hasta pasar a un ref propio. Las tareas de Claude Code
  no salen de la máquina.
- **Decision**:
  - El fichero local sigue siendo la fuente de verdad. Su réplica vive en la
    rama `crux/tasks` del docs repo del proyecto, o del repo suelto sin docs
    repo. La escribe `lib/task-sync.mjs` con plumbing de git —sin worktree,
    checkout ni daemon—, sin firma y sin hooks, con `[skip ci]`.
  - Fusión en tres vías contra lo último sincronizado. Si cambió en las dos
    máquinas, gana el `updated` más reciente y la otra se guarda como
    `.conflicto-`. Los borrados viajan en `.removed`, con la fecha de creación
    para que reutilizar un nombre no borre la tarea nueva.
  - Se publica en segundo plano tras cada escritura, con una marca de
    pendiente previa. `crux sync` trae y reintenta; `--leave` falla si algo
    sigue sin publicar.
  - Al abrir, retomar o volver tras horas a una sesión, las tareas abiertas se
    enseñan a la persona como recordatorio, y al agente se le dice que no las
    empuje. `crux workspace resume` las abre en otra máquina.
  - Las que tienen la propuesta fusionada se marcan y, sin espacio vivo, se
    archivan: al medirlo, 8 de 14 registros seguían en `proposed` con la
    propuesta ya fusionada.
  - En un repo público de GitHub no se publica —un registro lleva decisiones a
    medio pensar—, salvo con `"tasks": { "sync": true }`. Si no se puede
    comprobar la visibilidad, tampoco, y queda pendiente.
- **Consequences**:
  - Cerrar en una máquina y abrir en otra deja la tarea donde estaba, sin que
    nadie haga nada.
  - `main` del docs repo sigue siendo solo conocimiento, y `doctor` no ve la
    rama.
  - Quien tenga acceso al docs repo ve las tareas en esa rama. En un proyecto
    compartido es transparencia; si no se quiere, `tasks.sync: false`.
  - Las fechas del registro pasan a llevar segundos: la de creación identifica
    una tarea archivada, y una nueva con el mismo nombre en el mismo minuto se
    borraba.
  - La primera ronda en una máquina con historia tarda más (9 s con 8
    propuestas que consultar); las siguientes, alrededor de un segundo.
  - El espacio de trabajo en sí —puertos, ruta del worktree— sigue siendo de
    cada máquina: `resume` lo crea de nuevo.
- **Reversibility**: alta. Con `tasks.sync: false` o `CRUX_TASK_SYNC=0` todo
  vuelve a ser local, y la rama se borra sin tocar nada más.
- **Related**: `ADR-012`, `ADR-015`, `STANDARD.md` §La tarea
