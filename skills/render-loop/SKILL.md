---
name: render-loop
description: Iterate on layout changes to a rendered output (PDF, document, generated image, email template) by looking at the real result: render without a browser or session, rasterize, zoom into the touched area and compare before and after stacked. Use when working on subjective design notes, when there is no reference to measure against, or when you need to confirm visually that a change is noticeable and not just applied.
---

# render-loop

A short loop for layout changes: **edit, render, look, adjust**. It works when
the reference is a person's judgement.

Complementary to `/visual-diff`, which measures against a reference. If an
official design exists to compare against, that is the tool; this one is for when
there isn't.

## 1. A deterministic renderer, outside the application

The first thing is to be able to produce the output **without navigating the
application by hand**: no session, no clicking, with the same data every time.
Usually that means a small script that mints whatever credential is needed and
calls the render route directly.

Three things that script must do, and that produce false results if missing:

**Replicate the production pipeline's flags.** If the production render launches
the headless browser with specific flags, the script must use exactly the same
ones. Rendering without them produces artifacts (black headers, different
composition) that look like design defects and are not.

**Wait for fonts.** Without waiting for them to be ready, the output uses the
fallback ones and you are measuring a font nobody will see.

**Cancel animations.** Animation libraries often start at zero opacity and don't
complete in headless: the output can come out **blank** with no error at all.

## 2. Rasterize

Convert the output to an image at a resolution that is comfortable to look at,
not the highest possible. For multipage documents, limit it to the page you are
touching.

## 3. Zoom into the touched area

Looking at the whole page is no use for judging two pixels.

```bash
python3 <this-skill-directory>/scripts/inspect.py zoom page.png 40 290 310 440
```

And then **open the PNG and look at it**. That is the step that gives value to
everything else; without it this is just generating files.

## 4. Compare before and after stacked

Essential for size changes: a one-pixel jump is measurable but may not be visible
until you see them side by side.

```bash
python3 <this-skill-directory>/scripts/inspect.py stack before.png after.png \
  --box 40 280 310 440
```

## 5. Force the worst case before accepting anything

If the output has fixed-size canvases, **content that doesn't fit is clipped
without warning**. Validating with the usual example is not enough.

Before closing a change, identify and force the domain's real edge cases: the
longest possible text, the label with the most characters, the empty field, the
value that doesn't resolve. Force them in the local data and **restore them
afterwards**.

It is worth leaving that list written in the project documentation: they are
concrete facts (which is the longest text and how many characters it has) that
nobody remembers two months later.

## 6. Measure the real geometry of assets

**Positioning or sizing an image by its box doesn't work, because its box is not
its content.**

```bash
python3 <this-skill-directory>/scripts/inspect.py asset public/logo.png
python3 <this-skill-directory>/scripts/inspect.py asset public/icon.svg
```

It reports the real transparent margin of a PNG and the declared aspect ratio of
an SVG. Real cases that cost several attempts each: a PNG with 28% transparency
at the top, whose content fell 85 px below its coordinate; another with 27% on
the right, which looked a third smaller than it could be; an SVG with a 3.44:1
ratio put in a square box, which rendered as a strip.

**Measure the asset before touching the number.**

## 7. Put a regression guard in place

When an output is outside the scope of what you are changing but can break by
accident, a fingerprint protects it: render, rasterize, store the hash of each
page and compare on every run. It fits well in a pre-push hook, tolerating that
the local environment may not be up.

**A guard that has never been seen to fail is worthless.** Always validate it in
the negative: cause the change, check that it trips, and revert. It is the only
way to know you are measuring what you think.

## Warning: the media variant wins

If the render forces a media type (typically print), **the style rules specific to
that media are the ones that apply**, not the base ones.

A change to the base class may have no effect on the output, and at the same time
make it look like the regression guard is broken when it is actually working
fine. When touching a rendered output, change the right variant.

## Limit

This doesn't detect what you don't think to try. For systematic coverage after a
batch of changes, use `/visual-diff` with a battery of scenarios.

## Related

- `/visual-diff`: measure against a reference
- `/visual-test`: inspect web pages across viewports
