---
name: deploy-watch
description: Vigilar un despliegue después de fusionar hasta confirmar que la versión nueva está en producción y funciona: esperar a que llegue, comprobar que las rutas responden sin errores, mirar lo que el cambio tocaba y decir cómo revertir si algo falla. Usa justo después de fusionar una propuesta que se despliega sola, cuando alguien pregunte si ya está en producción, o cuando un despliegue haya terminado en verde y nadie haya mirado la web de verdad.
---

# deploy-watch

Fusionar no es desplegar, y desplegar en verde no es funcionar. Entre las dos
cosas hay un hueco en el que nadie mira: el CI dice que construyó, la
plataforma dice que publicó, y el primero que abre la web es un usuario.

Esto cierra ese hueco. Es el último paso del ciclo antes de cerrar la sesión.

## Cuándo aplica

- Después de fusionar una propuesta cuyo despliegue arranca solo.
- Después de un despliegue manual (`/deploy-fallback`).

## Cuándo no

- Cambios que no se despliegan: documentación interna, el propio repo de docs.
- Librerías que se publican con versión: ahí la comprobación es instalar la
  versión publicada en un proyecto limpio, no abrir una URL.

## Qué declara el proyecto

El kernel no sabe dónde vive cada proyecto. Lo declara su `crux.json`:

```json
"deploy": {
  "url": "https://<dominio>",
  "paths": ["/", "/<ruta-importante>"]
}
```

Con varios repos desplegables, uno por repo:

```json
"deploy": {
  "repos": {
    "<repo>": { "url": "https://<dominio>", "paths": ["/"] }
  }
}
```

`paths` son las pocas rutas que, si fallan, se nota: la portada y lo que más
se usa. No el sitemap entero.

## El recorrido

### 1. Esperar a que llegue la versión nueva

Un 200 justo después de fusionar suele ser **la versión anterior** respondiendo
mientras la nueva se construye. Hay que esperar a algo que solo tenga la nueva:
un texto que el cambio añade, o el identificador del commit si la aplicación lo
expone.

```bash
bash <directorio-de-esta-skill>/scripts/smoke.sh --expect "<texto que solo tiene la versión nueva>"
```

Si el cambio no añade nada visible que buscar, se espera a que la plataforma
dé el despliegue por terminado y se dice que no se pudo confirmar la versión.

### 2. Las rutas responden

El mismo script comprueba cada ruta declarada: código, tiempo y si el cuerpo es
en realidad una página de error servida con 200, que algunos frameworks hacen.

Salida: `0` todo responde, `1` alguna ruta falla, `3` la versión nueva no llegó.

### 3. Lo que el cambio tocaba

Las rutas genéricas no ven un cambio concreto. Se abre **lo que tocó el diff**
en producción:

- **Interfaz**: se mira renderizado en móvil y escritorio, con `/visual-test`.
  Se compara con lo que se vio en la vista previa de la propuesta.
- **API**: se llama al endpoint afectado con una petición real que no escriba
  datos.
- **Datos**: la migración está aplicada y la aplicación arranca contra ella.

### 4. Si algo falla

No se arregla a ciegas en producción. Por orden:

1. **Revertir**: se abre una propuesta con `git revert` del merge y se
   fusiona. Lo que vuelve es algo que ya funcionaba; el arreglo se hace
   después, con calma y con su ciclo.
2. Si la plataforma permite volver al despliegue anterior con un clic, eso es
   más rápido que el revert, pero **se hace también el revert**: si no, el
   siguiente despliegue vuelve a publicar el fallo.
3. Se investiga con `/root-cause`, empezando por las señales de producción
   (`/prod-signals`).

### 5. Contarlo

Una línea basta si todo está bien: qué versión, qué rutas, cuánto tardaron.
Si algo falló: qué, desde cuándo, qué se hizo y qué queda.

## Lo que cuesta

Casi nada. El script no lee páginas enteras en el contexto: devuelve una línea
por ruta. La parte cara es el paso 3 cuando hay interfaz, y es la misma
revisión visual que ya se hizo en la vista previa, ahora contra producción.

## Anti-patterns

- **Dar por desplegado lo fusionado.** La plataforma puede haber fallado, o
  seguir construyendo.
- **Comprobar solo la portada.** El cambio casi nunca está en la portada.
- **Arreglar en caliente sobre producción.** Primero se vuelve a lo que
  funcionaba; el arreglo pasa por el ciclo.
- **Revertir desde la plataforma y no en git.** El siguiente despliegue
  resucita el fallo.

## Relacionado

- `/flow` — esto es su paso 6c
- `/visual-test` — para mirar la interfaz en producción
- `/prod-signals` — cuando algo falla y hay que ver qué dice producción
- `/deploy-fallback` — cuando el despliegue automático no está disponible
