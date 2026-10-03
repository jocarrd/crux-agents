# motion-video — method and rationale

## Closed-form springs

A fixed curve goes from A to B always the same way. A spring accelerates,
overshoots a touch and settles: it has mass. In closed form it is still a pure
function of time, so frame 812 is painted without simulating the 811 before it.

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
// A value with several targets: one spring per change, summed. keys = [[t, value], ...]
function track(t, keys, k = 170, d = 20) {
  let v = keys[0][1];
  for (let i = 1; i < keys.length; i++) v += (keys[i][1] - keys[i - 1][1]) * spring(t - keys[i][0], k, d);
  return v;
}
```

Stiff (k 260-320) for buttons and advancing borders; medium (170) for cards and
camera; slow and without bounce for large typography and logos.

## Measured failures

- **An image that changes `src` inside `seek`** does not finish loading before
  the capture and comes out empty. Preload them all and toggle `display`.
- **White logos on a light background** disappear. They go on a dark pill.
- **Giant words at fixed width** overflow the canvas. Measure them once with the
  font loaded and fit the size to the width.
- **Splitting a text into letters on every `seek`** rebuilds the DOM on every
  frame. Split it once and reuse it while the text does not change.
- **A curtain that stays visible** covers the next scene for a few frames. Its
  visibility is cut as soon as it ends, not with a margin.
- **Non-technical audience:** a terminal overwhelms. Steps in plain language;
  the commands, if at all, in a collapsible.

## Sound without being able to listen to it

Synthesising is writing samples: kick (sine with pitch drop), snare (filtered
noise), cymbals (high-passed noise with a long decay), strings and brass
(detuned sawtooth waves with a filter), choir (sawtooth waves by formants at
750, 1150 and 2700 Hz), Freeverb-style reverb and echo. Each effect is placed at
the exact second of the cut it accompanies.

What cannot be heard is measured. Energy per band over a body section:

```bash
for b in "20 60" "60 150" "150 400" "400 1500" "1500 5000" "5000 16000"; do set -- $b
  ffmpeg -ss 8 -to 19 -i music.wav -af "highpass=f=$1,highpass=f=$1,lowpass=f=$2,lowpass=f=$2,volumedetect" -f null - 2>&1 | grep mean_volume
done
```

A healthy mix falls about 3 dB per band towards the highs. A peak at 400-1500 is
a choir or a pad covering the rest; a gap at 1500-5000 leaves the melody without
presence. `volumedetect` by sections confirms the shape: silence before the
drop, a hit on the drop.

Mix with the image and normalisation in one step:

```bash
ffmpeg -i video.mp4 -i music.wav -map 0:v -map 1:a -c:v copy \
  -af "alimiter=limit=0.95,loudnorm=I=-14:TP=-1.5:LRA=11" -ar 48000 -c:a aac -b:a 192k \
  -shortest -movflags +faststart final.mp4
```

## Motion blur

Render at `fps × sub` and average groups of `sub` frames:

```bash
ffmpeg -framerate 120 -i f%05d.png -vf "tmix=frames=4,select='eq(mod(n\,4)\,3)',setpts=N/30/TB" -r 30 ...
```

## Where it comes from

From the method made public in September 2026 around videos generated with
language models (seek(t), springs, beat grid, scored critique loop) and from a
real video made with this skill, where the failures above were measured.
