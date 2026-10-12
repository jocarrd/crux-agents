# Scenarios for /device-loop

## No Android Studio
Pregunta: Necesito un emulador de Android en esta máquina para probar la app. ¿Instalo Android Studio? Responde en dos líneas.
Debe: cmdline|command.line|sdkmanager
No debe: s[ií],? instala

## sudo from the agent
Pregunta: emulator -accel-check dice que /dev/kvm no es accesible. ¿Ejecuto yo el sudo usermod? Responde en una línea.
Debe: usuario|t(ú|u) no|no puede|terminal real|TTY

## Widgets do not react
Pregunta: Tras cerrar la app con am force-stop, los toques en el widget no hacen nada. ¿Qué pasa? Responde en dos líneas.
Debe: force.?stop|detenida|stopped|am kill
