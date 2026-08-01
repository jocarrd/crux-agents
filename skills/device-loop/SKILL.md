---
name: device-loop
description: Levantar y validar una app móvil React Native o Expo en un dispositivo Android físico vía adb, viendo la pantalla real con screencap e iterando con Fast Refresh sobre un development build. Usa cuando haya que probar la app nativa de verdad, reproducir un bug que solo ocurre en release, validar superficies que el navegador no reproduce (mapas GL, cámara, sensores) o hacer una pasada de QA en dispositivo.
---

# device-loop

El objetivo es que el agente **vea** la app nativa real y pueda iterar sobre
ella. La vía es un dispositivo Android físico por `adb` más `screencap`.

Para ver cambios de código en vivo hace falta un **development build** con
Metro y Fast Refresh. Para validar un APK ya construido basta instalar,
lanzar y capturar.

Es la hermana nativa de `/visual-test`. Se usa dispositivo físico y no
emulador porque sin virtualización por hardware el emulador va por software y
cualquier superficie GL sufre hasta ser inservible.

## Cuándo usar

- Hay que probar la app nativa, no una aproximación en navegador.
- Validar superficies que el navegador no reproduce fielmente.
- Reproducir un bug que solo aparece en el APK de release. Caso típico: las
  variables de entorno que el bundler inyecta en desarrollo pero no en
  release cuando se leen dinámicamente.

## 1. adb sin sudo

No hace falta el SDK entero. Descarga solo las platform-tools a una ruta
estable, no a un directorio temporal de sesión:

```bash
cd ~ && curl -sSL -o pt.zip \
  https://dl.google.com/android/repository/platform-tools-latest-linux.zip
unzip -q -o pt.zip && rm pt.zip
export PATH="$HOME/platform-tools:$PATH"
adb version
```

## 2. Permisos del dispositivo

Es donde se pierde más tiempo la primera vez.

1. En el móvil: Ajustes, Información del teléfono, tocar siete veces el número
   de compilación para desbloquear las opciones de desarrollador.
2. Activar **depuración USB**. Algunos fabricantes exigen además activar la
   instalación por USB.
3. Conectar el cable en modo **transferencia de ficheros**, no en solo carga.
4. Aceptar en el móvil el diálogo de permitir la depuración, marcando
   "permitir siempre".

Si `adb devices` responde `no permissions (missing udev rules)`, falta la
regla udev. **Esto lo tiene que ejecutar el usuario en una terminal real**: el
agente no puede, porque `sudo` necesita un TTY para pedir la contraseña.

```bash
sudo tee /etc/udev/rules.d/51-android.rules >/dev/null <<'EOF'
SUBSYSTEM=="usb", ATTR{idVendor}=="XXXX", MODE="0666", GROUP="plugdev"
EOF
sudo udevadm control --reload-rules && sudo udevadm trigger
```

El `idVendor` sale de `lsusb`. Después hay que **desconectar y reconectar** el
cable, y reiniciar el servidor:

```bash
adb kill-server && adb start-server && adb devices -l
```

Debe salir `device`, no `unauthorized` ni `no permissions`.

### Depuración inalámbrica

Sin cable ni udev, en Android 11 o superior. Opciones de desarrollador,
depuración inalámbrica, con el móvil y el PC en la misma red:

```bash
PAIR=$(adb mdns services | grep pairing | awk '{print $3}' | head -1)
adb pair "$PAIR" <codigo-de-6-digitos>
adb connect $(adb mdns services | grep connect | awk '{print $3}' | head -1)
```

Dos avisos: el error `protocol fault (couldn't read status message): Success`
suele significar que **sí** se vinculó — compruébalo en la lista de
dispositivos emparejados del móvil. Y si la red tiene aislamiento de clientes,
mDNS se ve pero la conexión TCP da "no route to host": ahí toca USB.

## 3. Ver la pantalla

```bash
adb exec-out screencap -p > <ruta>/phone.png
```

Y después abrir el PNG para mirarlo.

**Si la captura sale negra**, casi siempre es que el foco está en la cortina de
notificaciones o en otra ventana, no en la app:

```bash
adb shell dumpsys window | grep mCurrentFocus
adb shell cmd statusbar collapse
adb shell input keyevent KEYCODE_HOME
adb shell monkey -p <package> -c android.intent.category.LAUNCHER 1
```

Las vistas GL montadas sobre `TextureView` se capturan bien. Si la app usa
`SurfaceView`, esa zona puede salir negra aunque el resto de la interfaz se
vea; no es un fallo de la app.

## 4. Iterar

### Con recarga en vivo

Los perfiles de preview y producción son builds de release y **no** conectan
con Metro. Para iterar hace falta un development build:

```bash
eas build -p android --profile development   # una vez, tarda
adb install -r <dev-client>.apk
pnpm start
```

A partir de ahí el bucle es: editar código, esperar al Fast Refresh, capturar,
validar. Las variables de entorno las inyecta Metro desde el fichero local, no
las del servicio de build.

### Validando un APK concreto

```bash
adb install -r <build>.apk
adb shell monkey -p <package> -c android.intent.category.LAUNCHER 1
adb exec-out screencap -p > shot.png
```

## 5. Navegar por la app

**En algunas capas de fabricante, `adb shell input tap` no llega a la app.**
Exigen un permiso extra de depuración que a su vez pide cuenta del fabricante
y SIM. El síntoma es que los toques no hacen nada, o que el gesto lo recibe el
fondo en vez del control. Los `keyevent` sí suelen funcionar.

El método que funciona en cualquier dispositivo es **abrir la pantalla por
código** en vez de navegar con toques: instrumenta temporalmente el montaje
para abrir la pantalla objetivo, deja que el Fast Refresh lo aplique, captura
y revierte el cambio.

Para que el efecto se ejecute hace falta un **montaje limpio**: Fast Refresh
preserva el estado y no vuelve a lanzar efectos con dependencias estables. Es
decir, forzar la parada de la app y relanzarla:

```bash
adb shell am force-stop <package>
adb shell am start -a android.intent.action.VIEW -d "<deep-link>"
adb shell input keyevent KEYCODE_BACK
adb exec-out screencap -p > shot.png
adb logcat -d -t 200 | grep -iE "ReactNative|Exception|FATAL"
```

Si la pantalla está apagada o bloqueada:

```bash
adb shell input keyevent KEYCODE_WAKEUP
adb shell wm dismiss-keyguard
```

`dismiss-keyguard` solo funciona si el bloqueo no es seguro; con PIN o huella,
lo desbloquea el usuario.

## Anti-patterns

- **Dar por bueno un cambio sin una captura que lo confirme.** Es el punto
  entero de la skill.
- **Validar en navegador algo que en la app se comporta distinto.**
- **Intentar `sudo` desde el agente.** Sin TTY no hay contraseña; se lo pides
  al usuario.
- **Fiarse de la primera captura tras lanzar.** Espera a que el foco sea la
  actividad principal y a que la pantalla haya pintado.

## Relacionado

- `/visual-test` — la hermana web, con Chrome headless
