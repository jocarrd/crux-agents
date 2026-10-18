---
name: visual-test
description: Visually inspect web pages and components at mobile (390px) and desktop (1280px) viewports with headless Chrome. Takes screenshots, detects horizontal scroll and locates the exact element that overflows, reports objective mobile-usability signals, runs a real accessibility audit with axe-core, and catches four things none of the above sees: content that an entrance animation leaves invisible forever, hydration failures, contrast that only fails on hover or in the active state, and the vertical rhythm between sections. Use when polishing responsive design, when someone reports that something looks wrong on mobile, when chasing a horizontal overflow, when reviewing entrance animations, or when you want to compare mobile and desktop before deploying.
---

# Visual test

Headless visual inspection with the system Chrome: see the page as on a real
phone, detect horizontal scroll and catch the culprit element. The real cases
behind each check and the full gotchas are in
`<this-skill-directory>/references/why.md`.

## Setup, once

It needs `google-chrome` or `chromium` (autodetected; forced with `CHROME_BIN`)
and the application running locally.

```bash
mkdir -p ~/.cache/visual-test && cd ~/.cache/visual-test
[ -d node_modules/playwright-core ] || npm i playwright-core >/dev/null 2>&1
cp "<this-skill-directory>/scripts/visual.mjs" .
```

## Usage

```bash
cd ~/.cache/visual-test
node visual.mjs shot http://localhost:3000/path /tmp/a.png [--scroll 560] [--desktop]
node visual.mjs audit <url> [<url>…]       # horizontal scroll
node visual.mjs bisect <url>               # which element overflows
node visual.mjs checks <url>               # mobile usability signals
node visual.mjs a11y <url> [--desktop]     # WCAG with axe-core (needs network)
node visual.mjs invisible <url> [<url>…]   # content that stays at opacity 0
node visual.mjs hydration <url> [<url>…]   # hydration failures
node visual.mjs states <url>               # contrast at rest and on hover
node visual.mjs rhythm <url>               # spacing between sections
```

**Open the screenshots and look at them.** It is not optional: the skill is for
seeing, not for deducing. No page is accepted without having looked at its
screenshot on mobile and on desktop, whatever the commands report.

## How to read the results

- `checks` gives hints, not verdicts (touch areas < 44px, text < 12px, images
  without alt, text stuck to the edge); some are intentional. `a11y` is the
  reliable source for accessibility.
- `audit`: `innerWidth=390 overflowH=0px ok` is fine; a larger `innerWidth`
  means something forces that width. Then `bisect`.
- `bisect`: the culprit is the node with `kids=0`; its ancestors show up because
  hiding them makes it disappear too.
- `invisible` exits with code 1 if it finds anything.
- `states`: the active state of tabs and the like has to be triggered by hand;
  axe only sees the one that comes selected.

Two rules for entrance animations: never hide a whole container, and exclude
whatever lives inside a carousel.

## Typical causes of horizontal scroll

- A flex item without `min-width: 0` with text that does not wrap. Fix it on the
  container.
- A full-bleed element with negative margins outside the container that sets the
  padding. Wrap it in an element with that padding.
- `overflow-x: hidden` on the root hides it but does not fix it. Look for the
  cause with `bisect`.

## Gotchas

- Measure after hydrating: scroll down in stages with a pause and wait for a
  selector that only exists once hydrated.
- Walk the page without returning to the top, or `invisible` gives false
  positives.
- Do not chain `| head`: the process dies before writing. Redirect to a file.
- Check that the port serves the application you think it does.
- After touching the root layout, restart the development server.
- If the error page for dynamic chunks appears, retry.
- Kill the development server by PID, never with `pkill`.

## Related

- `/device-loop` — the real app on an Android emulator
- `/render-loop` — iterate on a rendered output
- `/ui-behaviour` — that controls do something useful
