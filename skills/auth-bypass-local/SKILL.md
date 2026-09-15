---
name: auth-bypass-local
description: Saltar la autenticación en local para probar endpoints o interfaz protegidos sin sesión real, saltando a la vez la capa de servidor y la de cliente, con un doble candado que lo hace imposible de activar en producción. Usa cuando necesites reproducir o depurar un flujo autenticado —panel de administración, endpoints protegidos, roles— sin poder iniciar sesión, cuando quieras saltarte el login para ver una pantalla protegida en local, incluido con navegador headless.
---

# auth-bypass-local

Probar de verdad lo que está detrás del login, en local, sin sesión.

## La regla que hace que funcione

**Hay dos capas y hay que saltar las dos a la vez.** Es el error que cuesta la
tarde: se salta solo el guard del cliente, se entra a la interfaz, y todas las
llamadas al servidor devuelven 401 o 403. O al revés: el servidor acepta, pero
el guard del cliente no deja ni pintar la pantalla.

| Capa | Qué bloquea | Qué hay que hacer |
| ---- | ----------- | ----------------- |
| Servidor | El guard que valida el token y el que comprueba el rol | Devolver autorizado e inyectar un usuario ficticio |
| Cliente | El componente que envuelve las rutas protegidas | Dejar pasar sin sesión |

Además, el cliente sin sesión enviará las peticiones **sin cabecera de
autorización**: el servidor con el bypass activo tiene que aceptarlas.

## La regla que lo hace seguro

**Doble candado: una variable de entorno explícita Y que el entorno no sea
producción.** Los dos, en la misma condición:

```
bypassActivo = ENV_VAR === "1" && NODE_ENV !== "production"
```

Así, aunque la variable se filtre a un entorno de producción, el bypass sigue
sin poder activarse. Un solo candado no basta: una variable mal puesta en un
`env_file` te abre el panel de administración a internet.

En el cliente, la variable debe llegar **solo por el arranque de desarrollo**,
nunca por un fichero que se hornee en el build de producción. Colócala en el
fichero de entorno local que esté en el `.gitignore`, no en el que se
distribuye.

## El detalle del componente cliente

El guard suele llamar a hooks del proveedor de autenticación. Si haces el
early-return antes de esos hooks, violas las reglas de hooks y la aplicación
peta.

**Patrón envoltorio**: el componente externo decide si hay bypass y devuelve
los hijos directamente; el componente que llama a los hooks queda aislado en un
hijo que solo se monta cuando el bypass está apagado.

Ojo con el proveedor de autenticación: normalmente necesita seguir montado con
una clave pública válida, aunque no haya sesión. Sin eso, los hooks que
devuelven `null` pasan a lanzar excepciones.

## Verificar

Que la llamada protegida responda **sin token**:

```bash
curl -i http://localhost:<puerto>/<ruta-protegida>
```

Debe dar 200. Si da 401, el bypass del servidor no está activo; si la interfaz
no carga, es el del cliente.

## Conducir el navegador para ver bugs reales

Muchos fallos de un panel protegido no se ven con `curl`: crashes de
JavaScript, avisos de error en la interfaz, peticiones que fallan por el
preflight. Con el bypass puesto se puede conducir un navegador headless contra
la aplicación local, escuchando los errores de página y las respuestas con
código de error.

Un caso real: un reordenamiento usaba un método HTTP que la configuración de
CORS del servidor no permitía. Con `curl` el endpoint respondía perfectamente;
desde el navegador fallaba el preflight y la interfaz solo decía "Failed to
fetch". **Solo se veía conduciendo el navegador.**

De ahí un gotcha que merece la pena recordar: **la configuración de CORS suele
listar métodos explícitamente**. Un endpoint nuevo con un método no listado
falla desde el navegador aunque exista y funcione. Se comprueba con una
petición `OPTIONS` que declare el método.

## Al terminar

- Parar los servicios locales que levantaste.
- Comprobar que la variable del bypass no quedó en ningún fichero que vaya a
  un build.

## Relacionado

- `/visual-test` — inspección visual de la interfaz una vez dentro
