---
name: share-local
description: Abrir el entorno local a alguien de fuera con un túnel público, sin desplegar nada. Elige la vía disponible, arregla las direcciones absolutas de la aplicación para que la página no llegue rota, comprueba que se ve de verdad desde fuera y deja el túnel cerrado al terminar. Usa cuando haya que enseñar un trabajo en curso a un cliente o a un compañero, revisar un diseño entre varios, probar en un móvil real, o recibir una llamada de un servicio externo que necesita una dirección pública.
---

# share-local

Un túnel publica lo que corre en tu máquina bajo una dirección de internet. Sirve
para enseñar sin desplegar, que es justo lo que hace falta cuando el trabajo
todavía no está para producción.

## Cuándo usar

- Hay que enseñar un trabajo en curso a alguien que no tiene el entorno montado.
- Estás iterando un diseño con otra persona y las capturas no bastan.
- Quieres probar en un móvil de verdad, no en un navegador emulado.
- Un servicio externo (una pasarela de pago, un webhook) necesita llamarte a una
  dirección pública mientras desarrollas.

**No lo uses** como despliegue de pruebas permanente. Un túnel dura lo que dura
la sesión y su dirección cambia; para algo estable, despliega.

## Antes de abrir nada

Un túnel expone **todo lo que sirve ese puerto**, no solo la página que quieres
enseñar. Repasa en voz alta:

- ¿Hay un panel de administración accesible sin contraseña?
- ¿La base de datos local es una copia de producción con datos de personas?
- ¿Hay claves o ficheros de entorno que se sirvan por descuido?

La dirección es larga y aleatoria, pero eso es oscuridad, no seguridad. Si algo
de lo anterior es que sí, ciérralo antes o no abras el túnel.

## Elegir la vía

Por orden, según lo que ya haya en la máquina:

**1. cloudflared.** No hace falta instalarlo: `npx` lo trae, lo que además
esquiva la política de no descargar binarios sueltos de internet.

```bash
npx --yes cloudflared tunnel --url http://localhost:<puerto>
```

Su ventaja es que la dirección aguanta toda la sesión. Su pega, que el propio
programa avisa: *«may take some time to be reachable»*. A veces son segundos y
a veces el nombre no llega a resolverse —`NXDOMAIN` incluso preguntando a
`1.1.1.1`— con el túnel perfectamente registrado del otro lado. **Comprueba que
responde antes de repartir el enlace**, y ten preparada la vía de abajo.

**2. SSH puro.** Tampoco instala nada y responde en segundos, a cambio de que
la dirección rote. Es la vía fiable cuando la de arriba no resuelve.

```bash
ssh -tt -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 \
    -o ExitOnForwardFailure=yes -R 80:localhost:<puerto> nokey@localhost.run
```

Dos detalles que cuestan media hora si no se saben:

- **`-tt` no es opcional.** Sin terminal, el servicio abre el túnel pero no
  imprime la dirección, y te quedas con un proceso conectado y sin URL.
- **El usuario importa.** `nokey@` entra sin registro. Con tu propia clave
  necesitas haberla dado de alta antes, o te responde `Permission denied
  (publickey)` después de mostrarte el saludo de bienvenida, que despista.

No instales un binario descargado de internet solo para esto si la vía de SSH
está disponible: es más superficie de la que el problema merece.

## La trampa de verdad: las direcciones absolutas

**Este es el fallo que hace que el túnel "no funcione" cuando en realidad
funciona perfectamente.**

Muchas aplicaciones guardan su propia dirección y la escriben en los enlaces,
las hojas de estilo y las imágenes que generan. Si esa dirección sigue siendo
`localhost`, quien entra desde fuera recibe una página que le manda a buscar los
recursos a *su* propio ordenador. Ve un documento en blanco o sin estilos, y tú
ves el sitio perfecto porque tú sí tienes algo en ese puerto.

Sitios donde suele estar guardada:

- WordPress: `WP_HOME` y `WP_SITEURL`, o las opciones `siteurl`/`home`.
- Frameworks de JavaScript: la variable de entorno con la URL pública.
- Cualquier configuración con un campo tipo `base_url` o `app_url`.

La solución es que la dirección **se deduzca de la petición** en vez de estar
escrita. En un entorno local vale con distinguir lo que no es local:

```php
$host = $_SERVER['HTTP_HOST'] ?? '';
$es_local = $host === '' || preg_match('/^(localhost|127\.0\.0\.1|\[::1\])(:\d+)?$/', $host);
if (!$es_local) {
    $_SERVER['HTTPS'] = 'on';   // el túnel termina el cifrado por su cuenta
    define('WP_HOME', 'https://' . $host);
    define('WP_SITEURL', 'https://' . $host);
}
```

Comprobar lo que **no** es local, en vez de mantener una lista de proveedores de
túnel, evita tener que volver aquí cada vez que se cambia de servicio.

Y marca la conexión como segura: el túnel cifra de cara al visitante y te habla
a ti por HTTP plano. Si la aplicación no lo sabe, generará enlaces mezclados que
el navegador bloquea.

## Comprobar que se ve, no que está abierto

Que el proceso siga vivo no significa nada. Pide la página **por la dirección
pública** y mira lo que llega:

```bash
curl -sS -o /tmp/tunel.html -w "%{http_code} · %{size_download} bytes\n" \
     -m 45 https://<direccion-del-tunel>/<ruta>

grep -c "localhost" /tmp/tunel.html     # tiene que dar 0, o casi
```

Si quedan referencias a `localhost`, mira cuáles son: las que genera la
aplicación al vuelo se arreglan con lo de arriba; las que están guardadas en
base de datos (un icono de pestaña, una dirección canónica) suelen ser
cosméticas y no impiden la demo.

Y para estar seguro del todo, ábrela: una captura desde fuera con el ancho de un
móvil enseña en un segundo lo que un `curl` no cuenta.

## Si tiene que durar: supervisarlo

Una sesión de túnel se cae sola. Dejar el proceso a pelo significa que a la
media hora la persona a la que se lo enseñabas ve un error y tú no te enteras.

Lo que aguanta es un supervisor: un bucle que reabre la conexión cuando cae y
**deja escrita la dirección vigente en un fichero**, con espera creciente para
no machacar el servicio si está caído del todo.

Dos detalles al escribirlo:

- **Desacóplalo de la sesión** (`setsid`), o morirá contigo. Compruébalo:
  el proceso debe quedar colgando de `init`, no de tu terminal.
- **Cuidado con `pkill -f`.** El patrón que buscas también aparece en la línea
  de comandos del shell que ejecuta el `pkill`, así que se mata a sí mismo y el
  comando termina con un código extraño. Filtra por PID hijo, no por texto.

## La dirección cambia, y eso no tiene arreglo gratis

**Cada reconexión trae una dirección nueva.** Los servicios gratuitos solo dan
subdominio fijo a cuentas registradas: tanto localhost.run como Serveo piden
dar de alta tu clave pública entrando con Google o GitHub.

Y hay algo peor, porque no se ve venir: **la dirección también puede cambiar sin
que la conexión se caiga**. El proceso sigue vivo, tú crees que todo va bien, y
la dirección que repartiste empieza a devolver 503. Un supervisor que solo lee
la dirección al abrir la sesión se queda apuntando a la vieja para siempre.

Por eso hay que releerla mientras la conexión viva, no una sola vez:

```bash
while kill -0 "$ssh_pid" 2>/dev/null; do
  url=$(grep -oE '[a-z0-9-]+\.lhr\.life' "$salida" | tail -1)   # tail, no head
  [ "$url" != "$ultima" ] && { ultima="$url"; echo "https://$url" > "$fichero"; }
  sleep 3
done
```

El `tail -1` en vez de `head -1` es la mitad del arreglo: en la salida quedan
todas las direcciones que ha tenido la sesión, y la buena es la última.

Consecuencias prácticas:

- No prometas una dirección estable si no has registrado la cuenta antes.
- Escribe siempre la vigente en un sitio consultable en vez de darla por sabida.
- Si de verdad hace falta que no cambie, las vías son registrar la clave (un
  minuto, una vez), un túnel con nombre bajo un dominio propio, o una
  redirección remota contra un servidor tuyo. Elige antes de empezar, no
  después de haber repartido el enlace.

## Al terminar

Cierra el túnel. Mientras siga abierto, tu máquina está en internet.

```bash
pkill -f "localhost.run"      # o el proceso de cloudflared
```

Si lo dejaste corriendo en segundo plano dentro de una sesión de agente, mátalo
de forma explícita: no se cierra solo cuando termina la conversación.

## Señales de que algo va mal

| Lo que ves | Lo que suele ser |
|---|---|
| Túnel conectado pero sin dirección | Falta `-tt`: no hay terminal donde imprimirla |
| `Permission denied (publickey)` tras el saludo | Tu clave no está registrada en el servicio; usa la vía sin clave |
| Página en blanco desde fuera, bien desde dentro | Direcciones absolutas a `localhost`; ver arriba |
| Estilos ausentes y avisos de contenido mixto | Falta decirle a la aplicación que la conexión es HTTPS |
| Todo lento y a ratos caído | Límite del servicio gratuito; para algo sostenido, despliega |
