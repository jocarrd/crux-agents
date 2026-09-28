# Por qué se hace así

El procedimiento está en `SKILL.md`.

## Por qué un dispositivo físico

Sin virtualización por hardware, el emulador va por software y cualquier
superficie GL sufre hasta ser inservible.

## Por qué los toques no llegan

Algunas capas de fabricante exigen un permiso extra de depuración que a su vez
pide cuenta del fabricante y SIM. El síntoma es que los toques no hacen nada, o
que el gesto lo recibe el fondo en vez del control.

## Por qué un montaje limpio

Fast Refresh conserva el estado y no vuelve a lanzar efectos con dependencias
estables: la instrumentación que abre la pantalla no se ejecutaría sin forzar la
parada de la app.
