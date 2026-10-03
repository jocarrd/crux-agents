---
name: before-after
description: Show whoever decides the before and after of a visual change —the published version on the left, the new one on the right and a red bar in the middle, on desktop, tablet and mobile— and push nothing until they approve; once approved, those screenshots go with the PR. Use when you finish a change that can be seen —redesign, polish, new page, responsive—, when asked "enséñame cómo queda antes de subirlo", "pásame el antes y el después" or "quiero verlo en el móvil", or before pushing the branch of anything that touches the interface.
---

# before-after

A visual change is finished when **whoever decides** has seen it. This skill
prepares the before and the after for them, side by side, at three screen sizes,
so they can decide in a minute from their phone. The reason behind each step and
each gotcha: `<this-skill-directory>/references/por-que.md`.

## When to use

- The diff touches something that can be seen: interface, styles, a new page, a
  chart.
- Before proposing the change (`crux workspace finish`), after `/ship`.
- Again if, after showing it, there were changes: from the person's comments or
  from the proposal's review.

## When not to use

- Changes that cannot be seen: logic, backend, data, documentation.
- Iterating on a detail yourself while laying out: that is `/render-loop`.
- Measuring the deviation against an official design: that is `/visual-diff`.

## The procedure

### 1. Decide what is shown

The pages the diff touches, **not the whole site**, at three widths: desktop
(1440), tablet (820) and mobile (390). If there are pieces that are not pages
—a video, a PDF, a downloadable image—, they are generated and shown too, as a
file.

### 2. Capture both versions with the same script

The **before**, from what is published if the base is what is deployed;
otherwise, the base on another port from the main checkout. The **after**, from
the branch, preferably with the production build locally. Both with the same
script and the same data.

```bash
mkdir -p ~/.cache/visual-test && cd ~/.cache/visual-test
[ -d node_modules/playwright-core ] || npm i playwright-core >/dev/null 2>&1
cp "<this-skill-directory>/scripts/capture.mjs" .

node capture.mjs --base https://<published> --head http://localhost:<port> \
  --paths /,/<other> --widths 1440,820,390 --out <folder> \
  --hide '<selectors for cookie notices, chat and floating layers>'
```

### 3. Assemble the comparisons

```bash
python3 "<this-skill-directory>/scripts/compose.py" <folder> --lang es
```

It leaves in `<folder>/compare/` one montage per page and width (before on the
left, after on the right, red bar), in sections of about 3,000 px and in WebP.

### 4. Look at them before sending them

Open each montage. Whatever looks wrong is fixed before showing; tell capture
artefacts apart (see Gotchas).

### 5. Show them and wait

They are sent to whoever decides through the conversation channel, with one line
on what changed. Desktop and mobile first; tablet if something specific to it
changes. **Nothing is pushed** —neither push nor proposal— until they say yes.

### 6. Record the yes

```bash
crux visual approve <folder>/compare --note "<what was reviewed, in one sentence>"
```

It saves the `.crux-visual` receipt with the commit the capture was taken on. If
another commit goes in afterwards, the screenshots no longer show what is being
proposed: go back to step 2.

### 7. Propose

`crux workspace finish` reads the receipt and adds to the proposal a section
"Antes y después". Depending on the project's profile:

| `visual.publish` | What it does |
| ---------------- | ------------ |
| `branch` (default) | Pushes the images to a separate branch that is never merged (`visual.branch`, `crux-review` by default) and links them in the proposal |
| `none` (client repos) | Only the review note, without images and without leaving anything of ours in their repo |

If the proposal is already open and is shown again after comments:
`crux visual pr <number>` replaces that section instead of adding another.

## Gotchas

- **An empty chart in the capture** is usually the animation restarted when the
  window is resized; `capture.mjs` already waits. Check it in the browser before
  calling it a bug.
- **What loads on entering the screen** needs the page to be scrolled through;
  the script does it.
- **With a development server, the system Chrome may not paint;** the production
  build is better.
- **Cookie notices, chat and floating layers:** `--hide` with their selectors,
  which go in the project's adapter.
- **Fixed elements appear at the end** of the full capture: they belong to the
  capture, not the design.
- **Only the pages the diff touched:** nobody reviews twenty-seven images.

## Anti-patterns

- Sending only desktop.
- Showing the after without the before.
- Pushing "so they can see it in the proposal": what is shown for approval goes
  before pushing.
- Publishing screenshots of an earlier commit (it is not dodged by deleting the
  receipt).

## Related

- `/ship` — the gate that comes before; its gate 7 is the one the agent sees
- `/visual-test` — inspect a page at both widths while working
- `/render-loop` — iterate on a layout detail
- `/visual-diff` — measure against an official design
- `/flow` — where this fits in the cycle
