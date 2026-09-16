---
name: prod-signals
description: Leer qué está pasando en producción —logs, errores, estado de los contenedores, disponibilidad— desde las fuentes de solo lectura que declara el proyecto, agrupando los errores repetidos para que quepan en el contexto. Usa cuando algo falle en producción, después de un despliegue que no se comporta, antes de depurar un fallo que solo pasa en el servidor, o cuando pregunten si la web o la API están dando errores.
---

# prod-signals

Depurar un fallo de producción empezando por lo que alguien cuenta es empezar
por la versión que menos datos tiene. Producción ya sabe qué falla, cuántas
veces y desde cuándo: está en sus logs.

El problema es que un log son miles de líneas casi iguales. Esto las lee, se
queda con lo que parece un problema y agrupa las que solo cambian en fechas,
números o identificadores. Lo que llega al contexto es un resumen de veinte
líneas, no el log.

## Qué declara el proyecto

Las fuentes son **comandos de solo lectura**, en el `crux.json` del proyecto:

```json
"observability": {
  "sources": [
    { "name": "app", "command": "ssh <host> docker logs --since {since} <contenedor>" },
    { "name": "contenedores", "command": "ssh <host> docker ps --format '{{.Names}} {{.Status}}'" },
    { "name": "web", "command": "<cli de la plataforma> logs <proyecto> --since {since}" }
  ]
}
```

`{since}` se sustituye por la ventana que se pida. **Nunca un comando que
escriba, reinicie o borre**: esto se lanza sin preguntar, así que tiene que
poder lanzarse sin consecuencias.

El contrato es del equipo y vive en el repo de documentación, así que no se
bloquea nada. Si tiene cambios sin commitear, el script lo avisa antes de
ejecutar: un comando tocado a mano y olvidado se ejecuta igual.

Las credenciales no van en el comando: van en la configuración de la máquina
(`~/.ssh/config`, la sesión de la CLI). El `crux.json` está en git.

## Cómo se usa

```bash
bash <directorio-de-esta-skill>/scripts/signals.sh                 # todas, última hora
bash <directorio-de-esta-skill>/scripts/signals.sh --since 24h app # una fuente, un día
bash <directorio-de-esta-skill>/scripts/signals.sh --all contenedores
```

`--all` quita el filtro de errores: para fuentes de estado, donde cada línea
importa.

Salida: `0` leído, `1` alguna fuente no respondió, `2` el proyecto no declara
fuentes.

## Qué se hace con el resumen

1. **El grupo que más se repite no es siempre el importante.** Un aviso que
   sale en cada petición desde hace meses es ruido; un error que empezó hace
   veinte minutos es la noticia. Se compara con una ventana anterior
   (`--since 24h` frente a `--since 1h`) antes de concluir.
2. **Se cruza con lo último desplegado.** Si el error empieza justo después de
   un despliegue, el diff de ese despliegue es el primer sospechoso.
3. **Se sigue con `/root-cause`**, que es donde se reproduce y se arregla. Esto
   da el punto de partida, no el diagnóstico.

## Lo que cuesta

Lo que se lee del log no entra en el contexto: entra el resumen, que tiene un
tope de grupos por fuente (`--max`, 15 por defecto). Una consulta ronda unos
pocos miles de tokens, frente a los cientos de miles de volcar el log.

## Lo que esto no es

No es un sistema de alertas ni vigila producción de forma continua. Se lanza
cuando hay motivo. Tener un agente mirando producción las veinticuatro horas
solo compensa con tráfico y equipo detrás; a escala de pocas personas, lo que
compensa es que cuando alguien pregunte, la respuesta tarde un minuto.

Si el proyecto ya tiene alertas —un monitor de disponibilidad, un servicio de
errores—, la alerta es el disparador natural: quien la recibe lanza esto.

## Anti-patterns

- **Volcar el log entero en el contexto.** No cabe, y lo que importa se pierde.
- **Declarar comandos que escriben.** Esto se ejecuta sin confirmación.
- **Concluir con una sola ventana.** Sin comparar, no se sabe si el error es
  nuevo.
- **Poner credenciales en el `crux.json`.** Está en git.

## Relacionado

- `/root-cause` — lo siguiente, con el resumen delante
- `/deploy-watch` — cuando la señal aparece justo después de desplegar
- `/runbook` — cuando el incidente se ha resuelto y hay que dejarlo escrito
