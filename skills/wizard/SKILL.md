---
name: wizard
description: Generar un asistente interactivo en bash que lleve a una persona, paso a paso, por un procedimiento manual que el agente no puede hacer: dar de alta infraestructura, sacar credenciales de un panel ajeno, meter secretos en el CI o ejecutar una migración de una sola vez. Abre cada URL, dice qué copiar, recoge los valores y los escribe donde van. Usa cuando haya que configurar un servicio de terceros, cuando un despliegue dependa de secretos que alguien tiene que ir a buscar, cuando toque un cambio de infraestructura irreversible, o cuando el usuario diga que no se acuerda de los pasos o que ya explicó esto la última vez.
---

# wizard

Hay pasos que el agente no puede dar: entrar en un panel que exige la sesión de
una persona, pulsar «crear» en algo que cuesta dinero, leer un token que solo se
enseña una vez. Esos pasos acaban siempre igual: una lista de instrucciones en
el chat que se pierde al cerrar la sesión, y a los dos meses hay que volver a
explicarlos.

Un **wizard** convierte esa lista en un script ejecutable. Abre cada URL, dice
exactamente dónde pulsar y qué copiar, recoge el valor, lo escribe en su sitio
(`.env`, secreto de GitHub), confirma antes de lo irreversible y enseña cuántas
etapas quedan.

**No lo uses para lo que puede hacer el agente.** Si el paso se resuelve con un
comando, se ejecuta y ya.

## Lo que ya está resuelto

`template.sh` trae la biblioteca entera: progreso por etapas, puertas de
confirmación, apertura de URL en Linux, macOS y WSL, entrada oculta para
secretos, escritura idempotente en `.env`, `gh secret`/`gh variable` y resumen
final con lo que quedó pendiente.

**Tu trabajo es solo acotar el procedimiento y escribir sus etapas.** Todo lo
que hay por encima de la marca `ETAPAS` es idéntico en todos los wizards, y esa
uniformidad es la gracia: no se edita a mano.

Un wizard es de usar y tirar por defecto: se escribe en el scratchpad o en
`scripts/`, se ejecuta y se borra. Se commitea solo si el procedimiento se va a
repetir y merece vivir en el repo.

## Procedimiento

### 1. Acotar

Averigua todos los pasos manuales y todos los valores que salen por el camino.
**Lee el repo antes de preguntar**, nunca empieces en frío:

- Para configuración: `.env`, `.env.example`, `README`, `docker-compose*`, la
  config del framework y `.github/workflows/*`. Cada `secrets.*` y cada
  `vars.*` del workflow es un valor que el wizard tiene que producir.
- Para una migración o un cambio de infraestructura: el estado actual, el
  estado final y las acciones irreversibles que hay entre los dos.

Enseña al usuario la lista ordenada de etapas y qué valor produce cada una, y
que confirme. Puede añadir, quitar o reordenar.

**Hecho cuando** cada etapa tiene nombre y orden, y de cada valor sabes de
dónde lo saca la persona, dónde se escribe (`.env`, secreto, los dos o ninguno)
y si es secreto o público.

### 2. Trazar el camino de cada etapa

Por cada etapa, escribe el recorrido exacto: qué URL se abre, qué se hace allí,
dónde aparece el valor y qué variable rellena. Por ejemplo: «Panel → Developers
→ API keys → Reveal test key → copiar».

**Si no conoces la interfaz actual o el comando exacto, dilo y pregunta, o
míralo en la documentación.** Inventarse un menú que no existe deja a la
persona atascada delante de una pantalla que no se parece a lo que dice el
script, y ahí el wizard vale menos que nada.

**Hecho cuando** cada etapa son instrucciones que podría seguir alguien que no
ha visto el proyecto.

### 3. Escribirlo

Copia `template.sh` a su destino. Sustituye la etapa de ejemplo por una
`stage` por paso, en orden de dependencia, y ajusta `TOTAL_STAGES`.

Usa los ayudantes: `stage`, `say`/`step`, `open_url`, `ask`/`ask_secret`,
`write_env`, `set_secret`/`set_var`, `pause`/`confirm`.

Mantén el listón que pone la plantilla:

- Abre la URL **antes** de pedir el valor que está en ella.
- `ask_secret` para todo lo que sea secreto.
- `write_env` para todo lo que haya que persistir.
- `set_secret` solo para lo que de verdad necesita el CI.
- `confirm` antes de cualquier acción irreversible.
- Una etapa, una tarea. Cada `stage` limpia la pantalla, así que si metes tres
  cosas en una, la primera se va antes de que la persona la lea.

### 4. Comprobar y entregar

```bash
bash -n <script>          # sintaxis
shellcheck <script>       # si está instalado
chmod +x <script>
```

**No lo ejecutes tú de principio a fin**: abre navegadores y se queda esperando
a una persona. Se revisa leyéndolo: que cada valor del paso 1 se recoja y
acabe donde dijiste, y que cada nombre de `set_secret` coincida **exactamente**
con un `secrets.*` del workflow.

Dile al usuario cómo lanzarlo. Si el procedimiento se va a repetir, commitéalo
y enlázalo desde el README, para que la próxima persona ejecute el script en
vez de preguntarle a un agente.

---

*Adaptada de la skill `wizard` de
[mattpocock/skills](https://github.com/mattpocock/skills), licencia MIT.
`template.sh` conserva la estructura de la biblioteca original.*
