# Scenarios for /device-loop

## Taps do not arrive
Pregunta: En un Xiaomi, adb shell input tap no hace nada en la app. ¿Cómo llego a la pantalla de ajustes para capturarla? Responde en dos líneas.
Debe: c(ó|o)digo|deep.?link|instrument
No debe: KEYCODE_TAB|KEYCODE_ENTER

## sudo from the agent
Pregunta: adb devices dice no permissions (missing udev rules). ¿Ejecuto yo el sudo tee de la regla udev? Responde en una línea.
Debe: usuario|t(ú|u) no|no puede|terminal real|TTY
