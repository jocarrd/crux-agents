---
name: oauth-reauthorize
description: Regenerar el refresh_token de una integración OAuth cuando el flujo queda invalidado, levantando un servidor local efímero que captura el code del callback y guardando los tokens con permisos restrictivos. Usa cuando una integración empiece a fallar con invalid_grant al refrescar, tras revocar permisos manualmente, o al poner en marcha una máquina nueva donde falta el token.
---

# oauth-reauthorize

Rehace desde cero el flujo OAuth de una integración de escritorio.

## Cuándo usar

- Una integración devuelve `invalid_grant` al refrescar. El síntoma habitual
  es que el proveedor caducó el grant por falta de uso, o alguien revocó los
  permisos a mano.
- Máquina nueva donde el fichero de cliente ya está pero falta el token.
- Después de revocar el acceso manualmente.

## Precondiciones

- Un `client.json` de tipo **escritorio** en el directorio de configuración de
  la integración. El tipo importa, ver los gotchas.
- La cuenta con la que vas a autorizar tiene realmente el acceso al recurso.
- El puerto de loopback que vas a usar, libre.

## Uso

```bash
python3 <directorio-de-esta-skill>/scripts/oauth-authorize.py \
  --dir ~/.config/<servicio> \
  --scope "<scope>"
```

Opcionalmente `--port`, y `--auth-url`/`--token-url` si el proveedor no es
Google.

El script imprime la URL de consentimiento y abre el navegador. Tras aceptar,
el proveedor redirige a `127.0.0.1`, el servidor efímero captura el `code`, lo
intercambia por tokens y los escribe con permisos 600.

## Verificar

No des por bueno el flujo porque el script diga OK: **haz una consulta real**
contra la API con el `access_token` recién obtenido. Un token que se escribe
pero no autoriza nada es el fallo más fácil de pasar por alto, y aparece
cuando el scope pedido no es el que la API necesita.

## Gotchas

- **La respuesta no incluye `refresh_token`.** Ocurre cuando el proveedor
  reutiliza un grant previo. El script ya pide consentimiento explícito y
  acceso offline para forzar uno nuevo, pero el cinturón de seguridad es
  **revocar el acceso a mano** en la página de permisos de la cuenta y repetir.
- **`redirect_uri_mismatch`.** El cliente OAuth tiene que ser de tipo
  escritorio: esos aceptan cualquier puerto bajo loopback por defecto. Los de
  tipo web exigen registrar el URI exacto.
- **El flujo fuera de banda está muerto.** El `urn:ietf:wg:oauth:2.0:oob` que
  aparece en tutoriales antiguos lleva años deprecado. Siempre loopback.
- **No uses puertos privilegiados** para el callback: obligan a root sin
  ninguna ventaja.
- **Una cuenta de servicio no sustituye esto** salvo que tenga permiso
  explícito sobre el recurso. Que exista un fichero de credenciales de cuenta
  de servicio en el directorio no significa que sirva; muchas integraciones
  solo admiten OAuth de usuario.

## Después

Los tokens son secretos: quedan con permisos 600 y **no se commitean**. Si el
proyecto necesita renovarlos de forma periódica, eso vive en un script aparte,
no aquí.

## Relacionado

- La documentación operativa del proyecto, para los scopes y el recurso
  concretos de cada integración
