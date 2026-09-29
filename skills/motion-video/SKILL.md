---
name: motion-video
description: Montar un vídeo de motion graphics renderizado desde código —de producto, de lanzamiento, de trayectoria o un explicativo— con la marca real, música sintetizada al pulso y un bucle de crítica sobre sus propios fotogramas. Usa cuando pidan un vídeo, un reel, un showreel, un anuncio animado, un vídeo para redes o "como esos vídeos de motion graphics", y antes de escribir la primera escena.
---

# motion-video

Un vídeo generado es un programa: una función que pinta el fotograma exacto de
cualquier instante. El guion es el 10 % del resultado; el resto es el arnés que
lo renderiza, le pone sonido y le obliga a mirarse. Los detalles de cada paso
están en `<directorio-de-esta-skill>/references/metodo.md`.

## Antes de escribir una escena

Reúne esto y enséñalo. Sin esto no se escribe código:

1. **Qué tiene que quedar.** Una frase: el hilo conductor. Todo el vídeo se
   comprueba contra ella. Si el público no es técnico, sin terminales ni jerga.
2. **Los activos reales.** Capturas del producto en marcha, logo, colores y
   tipografías de su sistema de diseño. Nunca redibujar la interfaz de memoria.
   Las cifras salen de los datos, nunca a mano.
3. **La lista de planos sobre la rejilla.** Elige un tempo (120 BPM da un pulso
   cada 0,5 s) y coloca cada corte en un pulso: plano, duración, texto en
   pantalla, sonido. Un gancho en los 2 primeros segundos y algo nuevo cada
   2 a 4. **Espera el visto bueno.**

## El contrato del escenario

Un HTML que expone `window.__duration` y `window.__seek(t)`. `seek` es puro:
el mismo `t` da el mismo fotograma, sin temporizadores, sin transiciones CSS,
sin estado entre fotogramas y con ruido sembrado. El primer fotograma se lee
entero: es la miniatura.

- Movimiento con **muelles de forma cerrada**, no curvas fijas. Un valor que
  cambia de destino varias veces suma un muelle por cambio (`track`).
- Texto dentro de algo que cambia: entra después del cambio y sale antes del
  siguiente.
- Nada de `will-change` en lo que la cámara escala: el texto sale borroso.

**Looks prohibidos**, porque delatan un vídeo generado: título centrado sobre
degradado, todo apareciendo por fundido, rótulos en las esquinas y marcos,
brillos sobre la interfaz, explosiones de partículas genéricas, un pulso muerto
sin nada nuevo.

## Sonido

Si hay pista, se mide su rejilla. Si no, se sintetiza sobre el mismo guion que
la imagen: cada golpe o barrido cae en el instante del corte que
acompaña. No se puede escuchar lo que se genera, así que **se mide**: energía
por bandas y sonoridad por tramos. Mezcla final a −14 LUFS.

## El bucle de crítica

Antes del render completo, y tantas rondas como haga falta:

```bash
scripts/sheets.sh salida.mp4 critica/     # hoja por pulso, prueba de móvil, tira
```

Mira las tres hojas como un director exigente, no como su autor. Puntúa de 1 a
10: gancho, legibilidad a 360 px de ancho, calidad del movimiento, variedad,
composición, fidelidad a la marca y sincronía con el sonido. Escribe los tres
peores problemas con su segundo, arréglalos y repite hasta que todo esté en 8 o
más.

## Renderizar

```bash
node scripts/render.mjs escenario.html fotogramas/ 120 1080 1350   # fps × sub, ancho, alto
scripts/encode.sh fotogramas/ salida.mp4 30 --sub 4 --audio musica.wav
```

Renderizar a 120 y codificar con `--sub 4` mezcla cuatro subfotogramas por
fotograma: desenfoque de movimiento real. Cuadruplica el tiempo; úsalo solo en el render final.
Salida en H.264 `yuv420p`: es lo que aceptan las redes.

Varios formatos (9:16, 1:1, 16:9) salen del mismo guion con una función de
maquetación por formato, no recortando uno de ellos.

## Entrega

El MP4, la hoja de contacto, el fotograma de portada y una línea con lo que
mejorarías en la siguiente ronda. **Nada se publica** sin el visto bueno de quien
lo encargó.

## Relacionado

- `visual-test` — capturar el producto en marcha para los activos.
- `render-loop` — iterar maquetación sobre una salida renderizada.
- `x-posts` — el texto que acompaña al vídeo cuando se publica.
