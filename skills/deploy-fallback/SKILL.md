---
name: deploy-fallback
description: Desplegar a un servidor propio sin pasar por el CI, construyendo la imagen en local y transfiriéndola por SSH para recrear el contenedor. Usa cuando el CI no esté disponible o se haya quedado sin cuota, cuando haya que desplegar urgentemente una rama que no ha pasado por revisión, o como plan B documentado de un pipeline que depende de un tercero.
---

# deploy-fallback

Ruta alternativa de despliegue: construir en local, transferir la imagen y
recrear el contenedor. Más lenta que el CI, pero no depende de nadie.

## Cuándo usar

- El CI se quedó sin cuota o está caído.
- Hay que desplegar una rama local urgentemente sin pasar por el flujo normal.
- Estás validando que el plan B existe **antes** de necesitarlo, que es la
  única forma de que funcione el día que haga falta.

## El pipeline

```
docker build (con los build-args de producción)
  └─ docker save | gzip -1 | ssh <host> 'gunzip | docker load'
       └─ ssh <host> 'docker compose up -d --force-recreate <servicio>'
            └─ invalidar el CDN si lo hay
```

`gzip -1` a propósito: en una subida doméstica el cuello de botella es la red,
pero comprimir al máximo tarda más de lo que ahorra. Prioriza velocidad.

## Antes de lanzar

Comprueba **qué vas a desplegar**. Al saltarte el CI también te saltas la
garantía de que lo que sube es lo que está en la rama principal:

```bash
git -C <repo> status
git -C <repo> log -1 --oneline
```

## La trampa de las variables horneadas en build

**Las variables que un framework de frontend expone al navegador se hornean en
el momento del build, no en el arranque del contenedor.** Es la causa número
uno de despliegues que parecen correctos y no lo son.

Consecuencia práctica: el fichero de entorno del servidor **no sirve** para
esas variables. Si el fichero de producción local tiene una clave de prueba, el
navegador arrancará con la clave de prueba aunque el runtime del servidor
muestre la de producción, y los servicios que dependan de ella fallarán de
formas confusas.

Verifica el fichero de entorno del que se construye, no el del servidor. Y si
puedes, haz que el script aborte cuando detecte una clave de entorno
equivocado: es una comprobación de dos líneas que se paga sola.

## Invalidar el CDN al terminar

Si delante hay un CDN, **purgarlo forma parte del despliegue, no es un extra**.

El fallo típico: el CDN sigue sirviendo el HTML del build anterior, que pide
recursos estáticos que ya no existen en el contenedor nuevo. Resultado: errores
404 en los bundles, el JavaScript no arranca y funciones como el inicio de
sesión dejan de responder sin ningún error visible en el servidor.

Síntomas que apuntan justo a esto: el botón de login no hace nada, errores de
acciones de servidor que no se encuentran, y 404 en las rutas de assets
estáticos. Se confirma en la consola del navegador en diez segundos.

## Verificación post-despliegue

No des un despliegue por bueno sin dos comprobaciones:

```bash
curl -sS -o /dev/null -w "HTTP %{http_code} | %{time_total}s\n" https://<dominio>/
ssh <host> 'docker ps --filter name=<servicio> --format "{{.Names}} | {{.Status}}"'
```

Esperado: 200 y el contenedor `Up` y sano. Si el healthcheck no pasa, el
contenedor está arriba pero la aplicación no.

## Gotchas

- **El build local sin caché del CI tarda bastante más** de lo que recuerdas.
  Cuéntalo antes de prometer un despliegue en cinco minutos.
- **Los servicios con caché persistente entre despliegues** no se limpian
  solos: si cambiaste lo que generan, hay que purgarla aparte.
- **Si el recreate falla por dependencias de red entre contenedores**, es un
  problema de orquestación, no del despliegue: mira el playbook de incidentes
  del proyecto.

## Relacionado

- La documentación de release del proyecto, para el pipeline canónico y el
  layout concreto del servidor
