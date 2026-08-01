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
- **Reversibility**: alta. Es una skill y un bloque de texto en las plantillas.
