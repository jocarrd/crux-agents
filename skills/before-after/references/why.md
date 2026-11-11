# Why it is shown this way

The procedure is in `SKILL.md`.

## Why a person

Tests do not see the screen, and gate 7 of `/ship` is passed by the agent. Here
a person approves, and does so from their phone: hence three widths, side-by-side
montages and sections that download well on a phone.

## Why an overview and an image per device

On a single sheet with the three devices the text is too small to read: desktop
lands at 44 % of its size, tablet at 41 %, mobile at 67 %; a 14 px line becomes
6 px. The sheet answers where something changed across sizes in one look; the
image per device, at 75 % or 100 %, answers what changed. The red boxes take the
eye to it: on a long page a change of a few pixels is otherwise missed, and a
change nobody intended is seen before it ships.

## How the boxes are found

From the pixels, not from the diff of the code: what matters is what the screen
shows, side effects included. The rows of both captures are paired as a patience
diff pairs lines: rows unique in both are anchors, and between anchors what is
equal at the top and at the bottom is paired too. Blank rows are never anchors,
so sections moved down by a change above them are still paired; the first
version, which only set aside what was equal at the very top and bottom, boxed
half a page when two sections changed at once.

What has no pair is compared in 8 px blocks by their mean colour, at the closest
of nine one-pixel nudges: a layout shift of a fraction of a pixel resamples an
image and moves an edge one pixel, and on a real page that alone boxed a whole
map. Changes thinner than 12 px are dropped, which is what such an edge leaves.
The boxes are numbered top to bottom, so a person can point at one.

How they are drawn is for a person who has a minute: what did not change fades a
little (white on a light page, black on a dark one) so the change stands in full
colour; the box is a thin red line with a white halo and a soft red glow outside
it, never inside, so it reads on a map or on white without tinting what it
marks; the number sits outside the box, not on top of the change. And each
change gets its own close-up, before and after at a size where it is seen
without looking for it.

Limit: when the same large image appears several times on a page and one of
them is removed, the pairing cannot tell which one went, and small extra boxes
appear inside the others.

Two captures of the same version differ in live data and animations, so
animations are frozen and, with `--repeat`, what changes on its own is left
unmarked. Measured on two pages and three widths captured twice from the same
version: 11 false marks without either guard, none with both.

## Names and frames

A path with a query becomes a short name, the path plus a fingerprint of the
query, and `pages.json` keeps the real path for the titles: the first real
capture produced file names of 120 characters. An element is captured with
everything it paints, children that stick out of its box included; a
full-bleed map inside a padded section came out with its close button cut.

## What was taken from vercel-labs/before-and-after

Their skill only places existing captures in the proposal; capture and marks
are ours. From it: padding the shorter capture at the bottom so both tops align;
capturing a component or a section instead of the whole page; showing a page
with no before as a preview; a single marked block in the proposal, replaced
whole on every publish and placed after the opening context, before the
implementation details; and never publishing a capture with a token or a
session in it.

## The same data and the same script

If the before and the after are captured differently, two ways of capturing are
being compared, not two versions.

## Why nothing is pushed before the yes

The proposal is for what has been approved. Proposing already means showing the
work to others, and what is shown for approval goes before. If another commit
goes in after the yes, the screenshots no longer show what is being proposed.

## The gotchas

- The full-page capture enlarges the window; the chart is redrawn from scratch
  and the photo comes out with the axes and no data. The script enlarges, waits
  and then fires.
- With a development server, a view transition that never ends leaves the system
  Chrome never painting; the script tries the browser that ships with Playwright
  first.
- A fake cookie is not always enough to remove the consent notice, because it is
  not universal.
- The mobile bottom navigation bar appears at the very bottom in the full
  capture.

## The anti-patterns

Half the traffic is mobile and it is where things break. Without the before, the
person has to remember what it was like, and then they do not decide: they
opine.
