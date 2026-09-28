# Los detalles de cada problema

El procedimiento está en `SKILL.md`. Aquí están el porqué y el material largo.

## Por qué comprobar antes de repartir el enlace

cloudflared avisa él mismo: *«may take some time to be reachable»*. A veces son
segundos y a veces el nombre no llega a resolverse (`NXDOMAIN` incluso
preguntando a `1.1.1.1`) con el túnel perfectamente registrado del otro lado.

La vía por `npx` esquiva además la política de no descargar binarios sueltos de
internet. Instalar un binario solo para esto es más superficie de la que el
problema merece.

## Los dos detalles de SSH que cuestan media hora

- Sin `-tt`, el servicio abre el túnel pero no imprime la dirección, y te quedas
  con un proceso conectado y sin URL.
- Con tu propia clave sin registrar, el servicio responde `Permission denied
  (publickey)` después de enseñar el saludo de bienvenida, que despista.

## Las direcciones absolutas

Es el fallo que hace que el túnel "no funcione" cuando funciona perfectamente.
La aplicación escribe su dirección en enlaces, hojas de estilo e imágenes; si es
`localhost`, quien entra desde fuera recibe una página que le manda a buscar los
recursos a su propio ordenador. Tú ves el sitio perfecto porque tú sí tienes
algo en ese puerto.

Comprobar lo que no es local, en vez de mantener una lista de proveedores de
túnel, evita volver aquí cada vez que se cambia de servicio. Sin marcar la
conexión como segura, la aplicación genera enlaces mezclados que el navegador
bloquea.

## Por qué un supervisor

Una sesión de túnel se cae sola. Dejar el proceso a pelo significa que a la
media hora la persona a la que se lo enseñabas ve un error y tú no te enteras.
Sin `setsid` el proceso muere contigo: tiene que quedar colgando de `init`, no
de tu terminal.

No busques el proceso con `pkill -f`: el patrón aparece también en la línea de
comandos del shell que ejecuta el `pkill`, que se mata a sí mismo. Filtra por
PID.

## La dirección cambia sin avisar

Los servicios gratuitos solo dan subdominio fijo a cuentas registradas: tanto
localhost.run como Serveo piden dar de alta tu clave pública entrando con Google
o GitHub.

Peor: la dirección puede cambiar **sin que la conexión se caiga**. El proceso
sigue vivo y la dirección que repartiste empieza a devolver 503. Un supervisor
que solo lee la dirección al abrir la sesión se queda apuntando a la vieja. Por
eso se relee mientras la conexión vive:

```bash
while kill -0 "$ssh_pid" 2>/dev/null; do
  url=$(grep -oE '[a-z0-9-]+\.lhr\.life' "$salida" | tail -1)   # tail, no head
  [ "$url" != "$ultima" ] && { ultima="$url"; echo "https://$url" > "$fichero"; }
  sleep 3
done
```

En la salida quedan todas las direcciones que ha tenido la sesión, y la buena es
la última: de ahí el `tail -1`.

Si de verdad hace falta que no cambie, elige la vía (registrar la clave, un
túnel con nombre bajo un dominio propio, una redirección remota) antes de
empezar, no después de haber repartido el enlace.

## Al terminar

Mientras el túnel siga abierto, tu máquina está en internet.
