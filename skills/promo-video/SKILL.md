---
name: promo-video
description: Montar un vídeo corto de producto para redes a partir de la aplicación real: elegir el estilo del encargo, capturar los planos, componer una línea de tiempo determinista, renderizar fotograma a fotograma y codificar a MP4. El estilo se decide cada vez; la skill fija el método, no la plantilla. Usa cuando quieras enseñar una web, una función nueva o un recorrido de producto en X, LinkedIn o Product Hunt, cuando pidan "un vídeo para redes", "una demo de 20 segundos" o "algo tipo Product Hunt".
---

# promo-video

Un vídeo de producto para una línea de tiempo dura entre 15 y 30 segundos, se ve
sin sonido y compite con todo lo demás. Lo que decide si funciona no es el
motor de render: es **qué se enseña y en qué orden**. Por eso esta skill separa
dos cosas que suelen venir pegadas:

- **El escenario** — el diseño, los colores, los rótulos, las transiciones. Se
  escribe entero para cada encargo. No hay plantilla.
- **El renderizador** — capturar planos, pedir fotogramas, codificar. Es
  siempre igual y está en `scripts/`.

Entre los dos hay un contrato de dos líneas (§3). Mientras el escenario lo
cumpla, puede tener el aspecto que quieras.

## 1. Elegir el estilo antes de escribir una línea

**No arranques con un diseño por defecto.** Pregunta o decide estas cuatro, que
son las que cambian el resultado:

| Pregunta | Por qué cambia el vídeo |
| -------- | ----------------------- |
| ¿Quién lo va a ver? | Programadores toleran densidad; clientes no. |
| ¿Qué tiene que quedar? | Un nombre, un dato o una sensación. Solo una. |
| ¿La interfaz es clara u oscura? | El escenario va al contrario, o el producto desaparece. |
| ¿Hay una cifra que aguante? | Si la hay, abre con ella. Si no la hay, no la inventes. |

Direcciones que funcionan, para elegir **una**, no para mezclarlas:

- **Producto sobre escenario.** La captura flota en un fondo de color con
  sombra larga. Es lo más neutro y lo que mejor envejece.
- **Pantalla completa.** El vídeo es la interfaz, sin marco, con rótulos
  encima. Íntimo y directo; exige que la interfaz esté impecable.
- **Documento.** Fondo de papel, tipografía grande, la captura como
  ilustración. Va bien para algo escrito o para un caso.
- **Terminal.** Texto monoespaciado que se escribe solo. Solo si el producto
  es una herramienta de línea de comandos: en cualquier otro caso es disfraz.
- **Rejilla.** Varias capturas a la vez, entrando escalonadas. Sirve para decir
  "hay mucho", no para que se lea nada.

Y una regla que ahorra discusiones: **el escenario no debe parecerse a la marca
que imitas.** Si copias la paleta de Apple, el vídeo se lee como una imitación
de Apple, no como tu producto.

## 2. Capturar los planos de la aplicación real

Nada de maquetas: se captura el producto funcionando. Tres cosas que, si
faltan, arruinan la captura:

**Esperar a la hidratación antes de tocar el scroll.** Si mueves la página
antes de que monte el JavaScript, los observadores de entrada se registran con
la página ya arriba y el contenido de más abajo **no llega a mostrarse nunca**.
La captura sale con huecos blancos donde había tarjetas.

**Recorrer la página entera y volver arriba.** Es lo que dispara las
animaciones de entrada. Después, esperar a que terminen: capturar a media
transición da elementos a medio opacar.

**Cerrar lo que tape.** Banner de cookies, avisos de sesión, chats de soporte.
Se cierran antes de disparar, no se recortan después.

Captura a `deviceScaleFactor: 2` y reduce luego. Capturar al tamaño final deja
el texto blando.

## 3. El contrato: una línea de tiempo que se pueda pedir por instante

El escenario es un HTML que expone dos cosas:

```js
window.__duration = 21.0;        // segundos
window.__seek = (t) => { ... };  // coloca TODO el vídeo en el instante t
```

`__seek` tiene que ser **puro**: para un mismo `t`, el mismo fotograma, se llame
cuando se llame y en el orden que sea. Nada de `requestAnimationFrame`, nada de
`transition` de CSS, nada que dependa del reloj real.

Es lo que separa este método de grabar la pantalla: el render no compite con la
velocidad de la máquina, así que no hay fotogramas saltados ni tirones. Puedes
renderizar a 60 fps en un portátil cansado.

Dentro de `__seek`, lo habitual es una lista de escenas con entrada y salida, y
una función de ventana que devuelve su opacidad. El resto —qué hay en cada
escena— es diseño libre.

## 4. Ritmo: se mide, no se estima

El error más fácil es que el recorrido vaya demasiado rápido. Se mide en
píxeles por segundo:

```
velocidad = pixeles_recorridos / duracion_de_la_escena
```

- **300-450 px/s**: se lee cómodo. Es el objetivo.
- **600+ px/s**: se intuye que hay contenido, no se lee.
- **900+ px/s**: mareo.

Si no cabe lo que quieres enseñar, **recorta el recorrido**, no alargues el
vídeo. Un vídeo de redes que pasa de 30 segundos pierde la mitad de la
audiencia.

Con una curva de aceleración, el pico está alrededor de 1,5 veces la media:
tenlo en cuenta al elegir el número.

## 5. Renderizar y codificar

```bash
node scripts/render.mjs <escenario.html> <carpeta-salida> [fps]
scripts/encode.sh <carpeta-salida> <salida.mp4> [fps]
```

Dos avisos que cuestan una tarde:

**El ffmpeg que trae Playwright no sirve.** Es una compilación recortada: solo
saca WebM/VP8. Necesitas uno con `libx264`. Si no hay `ffmpeg` en el sistema,
suele haber uno completo en `imageio_ffmpeg` de Python:

```bash
python3 -c "import imageio_ffmpeg,os;print(imageio_ffmpeg.get_ffmpeg_exe())"
```

**X no acepta WebM.** Quiere MP4 con H.264 y `yuv420p`. Sube el 1080p aunque
pese: X reencoda, y cuanto mejor sea el origen, mejor queda el resultado.

## 6. Comprobar antes de publicar

- Abre tres fotogramas sueltos —uno de la apertura, uno del medio y el cierre—
  y míralos. Es más rápido que ver el vídeo entero y detecta lo importante.
- Comprueba que el primer fotograma no sea negro, que es el que se usa de
  miniatura.
- Comprueba que se entiende **sin sonido y sin leer nada**. Si hace falta leer
  un párrafo, el vídeo no funciona.

## Relacionado

- `visual-test` — capturas y auditoría de la aplicación, sin sesión.
- `render-loop` — iterar maquetación viendo el resultado, sin vídeo de por medio.
- `drive-browser` — si hay que atravesar un login para llegar al plano.
