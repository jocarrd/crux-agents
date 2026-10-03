---
name: visual-diff
description: Objectively measure how far a rendered output (PDF, page, image) deviates from a visual reference, with a cell grid, mean error per cell, pre-blur against antialiasing, zones with semantic names and overlays that reveal misalignment. Use when an official design exists to compare against, when you want a ranking of which zones are worst, or as a safety net after a batch of layout changes that eyeball review doesn't cover.
---

# visual-diff

It answers one specific question: **how far am I from the reference, and where**.
It is the measurable half of visual work; the other half, when there is no
reference and the criterion is a person's, is `/render-loop`.

## When to use each

| Situation | Tool |
| --------- | ---- |
| There is an official design to compare against | **this one** |
| Before accepting a batch of changes | **this one** |
| Subjective notes: "bigger", "more air" | `/render-loop` |
| Confirming a change is noticeable | `/render-loop` |

## Usage

```bash
python3 <this-skill-directory>/scripts/imgdiff.py <current> <reference> \
  --out diff-out --grid 12x18 --blocks blocks.json
```

It accepts PDFs (rasterized with `pdftoppm`) or images. It produces `report.md`
sorted by descending deviation, `scores.json` and one overlay per page. It exits
with code 1 if any cell exceeds the threshold, so it works directly as a gate in
a hook or in CI.

It requires `python3` with `numpy` and `Pillow`, and `poppler` for PDFs.

## How it works, and why

1. **Rasterize both outputs at the same resolution** and fit the current one to
   the reference's size.
2. **Apply a pre-blur.** This is what makes comparison between different
   renderers usable: without it, antialiasing dominates the signal and
   everything looks different. With it, the real defects of position, size and
   colour survive.
3. **Split into a grid and compute the mean absolute error per cell.** One number
   per page says nothing actionable; per cell, it does.
4. **Ignore cells that are almost white in both.** They are the margins: without
   this filter they inflate the average and hide the real defects.
5. **Label each cell with its semantic block.** A report saying "the header is
   shifted" is actionable; one saying "cell 3,7" forces you to go look at the PNG
   to understand what is happening.
6. **Generate the overlay.** What matches comes out grey; misalignment shows up as
   a coloured ghost, blue where there is content only in the current one and warm
   where there is only in the reference.

## The semantic blocks

A JSON with the zones in normalized 0 to 1 coordinates, optionally per page:

```json
[{"name": "header",  "page": 1, "box": [0, 0, 1, 0.2]},
 {"name": "left-card", "page": 1, "box": [0, 0.28, 0.55, 0.52]}]
```

It is worth writing once: it turns the report from a list of coordinates into a
list of names where you already know where to make the change.

## The rule that decides whether the measurement is worth anything

**Fix the data before comparing.** If the current render carries different data
from the reference, you are measuring content and not design, and any real
difference gets buried under the noise.

The normal thing is to expose a mode in the application itself that fills the
output with the same data as the reference. Without that, the diff is
inconclusive and shouldn't be interpreted.

## Systematic coverage

A comparison against a reference measures the case you have rendered. If the
output has fixed-size canvases (typical in reports and documents), **content that
doesn't fit is clipped silently**, and eyeball review only detects what one
thinks to look at.

That is why it is worth accompanying it with a battery of scenarios that renders
the edge cases: the longest possible text, extreme values, empty fields, all the
variants of a label. It is the part that must be run without fail after touching
typography or spacing.

## Documented false positive

**If artifacts appear (black headers, badly composed blocks) in some viewers and
not in others, suspect the renderer before the design.** The usual cause is
launching the headless browser without the same flags the production pipeline
uses.

Any comparison script must replicate exactly those flags. This cost one team a
whole working day before it was documented.

## Related

- `/render-loop`: iterate when there is no reference and the criterion is
  subjective
- `/visual-test`: inspect web pages across viewports
