# motion-video — método y porqués

## Muelles de forma cerrada

Una curva fija va de A a B siempre igual. Un muelle acelera, se pasa un pelo y
se asienta: tiene masa. En forma cerrada sigue siendo función pura del tiempo,
así que el fotograma 812 se pinta sin simular los 811 anteriores.

```js
function spring(t, k = 170, d = 20) {
  if (t <= 0) return 0;
  const w0 = Math.sqrt(k), z = d / (2 * w0);
  if (z < 1) {
    const wd = w0 * Math.sqrt(1 - z * z);
    return 1 - Math.exp(-z * w0 * t) * (Math.cos(wd * t) + (z * w0 / wd) * Math.sin(wd * t));
  }
  return 1 - Math.exp(-w0 * t) * (1 + w0 * t);
}
// Un valor con varios destinos: un muelle por cambio, sumados. keys = [[t, valor], ...]
function track(t, keys, k = 170, d = 20) {
  let v = keys[0][1];
  for (let i = 1; i < keys.length; i++) v += (keys[i][1] - keys[i - 1][1]) * spring(t - keys[i][0], k, d);
  return v;
}
```

Rígido (k 260-320) para botones y bordes que avanzan; medio (170) para
tarjetas y cámara; lento y sin rebote para tipografía grande y logos.

## Fallos medidos

- **Una imagen que cambia de `src` dentro de `seek`** no llega a cargarse antes
  de la captura y sale vacía. Se precargan todas y se alterna `display`.
- **Logos blancos sobre fondo claro** desaparecen. Van en una pastilla oscura.
- **Palabras gigantes a ancho fijo** se salen del lienzo. Se miden una vez con
  la fuente cargada y se ajusta el tamaño al ancho.
- **Partir un texto en letras en cada `seek`** reconstruye el DOM en cada
  fotograma. Se parte una vez y se reutiliza mientras el texto no cambie.
- **Una cortina que sigue visible** tapa la escena siguiente unos fotogramas.
  Su visibilidad se corta en cuanto termina, no con margen.
- **Público no técnico:** una terminal agobia. Pasos en lenguaje llano; los
  comandos, si acaso, en un desplegable.

## Sonido sin poder escucharlo

Sintetizar es escribir muestras: bombo (seno con caída de tono), caja
(ruido filtrado), platos (ruido paso alto con caída larga), cuerdas y metales
(dientes de sierra desafinados con filtro), coro (dientes de sierra por
formantes a 750, 1150 y 2700 Hz), reverberación tipo Freeverb y eco. Cada
efecto se coloca en el segundo exacto del corte que acompaña.

Lo que no se oye se mide. Energía por bandas en un tramo de cuerpo:

```bash
for b in "20 60" "60 150" "150 400" "400 1500" "1500 5000" "5000 16000"; do set -- $b
  ffmpeg -ss 8 -to 19 -i musica.wav -af "highpass=f=$1,highpass=f=$1,lowpass=f=$2,lowpass=f=$2,volumedetect" -f null - 2>&1 | grep mean_volume
done
```

Una mezcla sana cae unos 3 dB por banda hacia los agudos. Un pico en 400-1500
es un coro o un pad que tapa el resto; un hueco en 1500-5000 deja la melodía sin
presencia. `volumedetect` por tramos confirma la forma: silencio antes del
drop, golpe en el drop.

Mezcla con la imagen y normalización en un paso:

```bash
ffmpeg -i video.mp4 -i musica.wav -map 0:v -map 1:a -c:v copy \
  -af "alimiter=limit=0.95,loudnorm=I=-14:TP=-1.5:LRA=11" -ar 48000 -c:a aac -b:a 192k \
  -shortest -movflags +faststart final.mp4
```

## Desenfoque de movimiento

Se renderiza a `fps × sub` y se promedian grupos de `sub` fotogramas:

```bash
ffmpeg -framerate 120 -i f%05d.png -vf "tmix=frames=4,select='eq(mod(n\,4)\,3)',setpts=N/30/TB" -r 30 ...
```

## De dónde sale

Del método que se hizo público en septiembre de 2026 alrededor de los vídeos
generados con modelos de lenguaje (seek(t), muelles, rejilla de pulsos, bucle
de crítica puntuado) y de un vídeo real hecho con esta skill, donde se midieron
los fallos de arriba.
