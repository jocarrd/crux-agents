---
name: share-local
description: Abrir el entorno local a alguien de fuera con un túnel público, sin desplegar nada. Elige la vía disponible, arregla las direcciones absolutas de la aplicación para que la página no llegue rota, comprueba que se ve de verdad desde fuera y deja el túnel cerrado al terminar. Usa cuando haya que enseñar un trabajo en curso a un cliente o a un compañero, revisar un diseño entre varios, probar en un móvil real, o recibir una llamada de un servicio externo que necesita una dirección pública.
---

# share-local

Publica lo que corre en tu máquina bajo una dirección de internet, sin
desplegar. Los detalles de cada problema y el supervisor completo están en
`<directorio-de-esta-skill>/references/por-que.md`.

**No es un despliegue de pruebas permanente:** el túnel dura lo que la sesión y
su dirección cambia. Para algo estable, despliega.

## Antes de abrir nada

El túnel expone **todo lo que sirve ese puerto**. Comprueba en voz alta: ¿hay un
panel de administración sin contraseña? ¿la base de datos local tiene datos de
personas? ¿se sirven claves o ficheros de entorno? Si algo es que sí, ciérralo
antes o no abras el túnel. Una dirección aleatoria no es seguridad.

## Elegir la vía

**1. cloudflared**, sin instalar nada:

```bash
npx --yes cloudflared tunnel --url http://localhost:<puerto>
```

La dirección aguanta la sesión, pero a veces tarda en resolver o no llega a
hacerlo (`NXDOMAIN`). Comprueba que responde antes de repartir el enlace.

**2. SSH puro**, si la primera no resuelve. Responde en segundos; la dirección
rota:

```bash
ssh -tt -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 \
    -o ExitOnForwardFailure=yes -R 80:localhost:<puerto> nokey@localhost.run
```

`-tt` es obligatorio (sin él no imprime la dirección) y el usuario es `nokey@`
(con tu clave hace falta haberla registrado). No instales un binario descargado
solo para esto.

## Las direcciones absolutas

Si la aplicación guarda su propia dirección como `localhost`, desde fuera llega
una página en blanco o sin estilos mientras tú la ves bien. Está en sitios como
`WP_HOME`/`WP_SITEURL` en WordPress, la variable de URL pública de un framework
de JavaScript, o un `base_url`/`app_url`.

La dirección se deduce de la petición cuando no es local, y la conexión se
marca como segura (el túnel cifra hacia fuera y te habla por HTTP):

```php
$host = $_SERVER['HTTP_HOST'] ?? '';
$es_local = $host === '' || preg_match('/^(localhost|127\.0\.0\.1|\[::1\])(:\d+)?$/', $host);
if (!$es_local) {
    $_SERVER['HTTPS'] = 'on';
    define('WP_HOME', 'https://' . $host);
    define('WP_SITEURL', 'https://' . $host);
}
```

## Comprobar que se ve

Que el proceso siga vivo no significa nada. Pide la página por la dirección
pública:

```bash
curl -sS -o /tmp/tunel.html -w "%{http_code} · %{size_download} bytes\n" \
     -m 45 https://<direccion-del-tunel>/<ruta>
grep -c "localhost" /tmp/tunel.html     # 0, o casi
```

Y ábrela con el ancho de un móvil. Las referencias a `localhost` guardadas en
base de datos (favicon, canónica) suelen ser cosméticas.

## Si tiene que durar

Supervísalo: un bucle que reabre la conexión cuando cae, con espera creciente,
desacoplado de la sesión (`setsid`) y que **relee la dirección mientras la
conexión vive** y escribe la vigente en un fichero (la última que aparezca en la
salida, no la primera). La dirección puede cambiar sin que la conexión se caiga.
El supervisor de ejemplo está en la referencia.

Cada reconexión trae una dirección nueva. No prometas una dirección estable sin
haber registrado antes la clave en el servicio, un túnel con dominio propio o
una redirección contra un servidor tuyo.

## Al terminar

Cierra el túnel **por su PID**. Nunca con `pkill` ni `killall`: matan por nombre
otros procesos, y el guardia de comandos destructivos los bloquea.

```bash
pgrep -af "localhost.run|cloudflared"   # localiza el PID
kill <PID>
```

Si lo lanzaste en segundo plano en una sesión de agente, no se cierra solo al
terminar la conversación.

## Señales de que algo va mal

| Lo que ves | Lo que suele ser |
|---|---|
| Túnel conectado pero sin dirección | Falta `-tt` |
| `Permission denied (publickey)` tras el saludo | Tu clave no está registrada; usa `nokey@` |
| Página en blanco desde fuera, bien desde dentro | Direcciones absolutas a `localhost` |
| Estilos ausentes y avisos de contenido mixto | La aplicación no sabe que la conexión es HTTPS |
| Lento y a ratos caído | Límite del servicio gratuito; para algo sostenido, despliega |
