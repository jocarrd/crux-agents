---
name: motion-video
description: Build a motion-graphics video rendered from code —product, launch, track record or explainer— with the real brand, music synthesised to the beat and a critique loop over its own frames. Use when asked for a video ("un vídeo"), a reel, a showreel, an animated ad, a video for social media or "como esos vídeos de motion graphics", and before writing the first scene.
---

# motion-video

A generated video is a program: a function that paints the exact frame at any
instant. The script is 10 % of the result; the rest is the harness that renders
it, gives it sound and forces it to look at itself. The details of each step are
in `<this-skill-directory>/references/metodo.md`.

## Before writing a scene

Gather this and show it. Without it, no code is written:

1. **What it has to end up as.** One sentence: the through-line. The whole video
   is checked against it. If the audience is not technical, no terminals and no
   jargon.
2. **The real assets.** Screenshots of the product running, logo, colours and
   typefaces from its design system. Never redraw the interface from memory.
   Figures come from the data, never by hand.
3. **The shot list on the grid.** Choose a tempo (120 BPM gives a beat every
   0.5 s) and place every cut on a beat: shot, duration, on-screen text, sound.
   A hook in the first 2 seconds and something new every 2 to 4. **Wait for the
   go-ahead.**

## The stage contract

An HTML that exposes `window.__duration` and `window.__seek(t)`. `seek` is pure:
the same `t` gives the same frame, with no timers, no CSS transitions, no state
between frames and with seeded noise. The first frame is read whole: it is the
thumbnail.

- Motion with **closed-form springs**, not fixed curves. A value that changes
  target several times adds one spring per change (`track`).
- Text inside something that changes: it enters after the change and leaves
  before the next one.
- No `will-change` on what the camera scales: the text comes out blurry.

**Banned looks**, because they give away a generated video: centred title over a
gradient, everything appearing by fade, labels in the corners and frames, glows
over the interface, generic particle explosions, a dead beat with nothing new.

## Sound

If there is a track, its grid is measured. If not, it is synthesised over the
same script as the image: each hit or sweep falls on the instant of the cut it
accompanies. What is generated cannot be listened to, so **it is measured**:
energy per band and loudness per section. Final mix at −14 LUFS.

## The critique loop

Before the full render, and as many rounds as needed:

```bash
scripts/sheets.sh output.mp4 critique/     # per-beat sheet, mobile test, strip
```

Look at the three sheets like a demanding director, not like its author. Score
from 1 to 10: hook, legibility at 360 px wide, quality of motion, variety,
composition, fidelity to the brand and sync with the sound. Write the three
worst problems with their second, fix them and repeat until everything is 8 or
more.

## Render

```bash
node scripts/render.mjs scene.html frames/ 120 1080 1350   # fps × sub, width, height
scripts/encode.sh frames/ output.mp4 30 --sub 4 --audio music.wav
```

Rendering at 120 and encoding with `--sub 4` blends four subframes per frame:
real motion blur. It quadruples the time; use it only for the final render.
Output in H.264 `yuv420p`: it is what social networks accept.

Several formats (9:16, 1:1, 16:9) come out of the same script with one layout
function per format, not by cropping one of them.

## Delivery

The MP4, the contact sheet, the cover frame and one line with what you would
improve in the next round. **Nothing is published** without the approval of
whoever commissioned it.

## Related

- `visual-test` — capture the product running for the assets.
- `render-loop` — iterate on layout over a rendered output.
- `x-posts` — the text that accompanies the video when it is published.
