# The cases behind each check

The procedure is in `SKILL.md`. Here are the real failures that gave rise to
each check.

## Why playwright-core in a cache

It launches the system Chrome instead of downloading a browser, and it is
installed in a cache directory next to the script because ESM resolves the
import relative to the file.

## The four checks nobody else does

Neither the build, nor the typecheck, nor axe sees any of these.

**`invisible`.** An entrance animation hides the element and reveals it on
entering the screen. If the trigger is lost (because the content loads on its
own and changes the page height after the positions are computed), the element
stays at `opacity: 0` forever. The HTML is there, the test passes and the user
sees nothing. If one item misses the trigger it is barely noticeable; if it is a
whole section, it is an inaccessible stretch of the page. An off-screen slide in
a horizontal carousel never intersects, hence excluding carousels.

**`hydration`.** A mismatch between what the server and the client paint makes
the framework throw away the HTML and repaint everything. It is only seen by
listening to `pageerror` while walking the page.

**`states`.** axe measures the resting state; a button can pass at rest and fail
on hover. If only one tab is active at a time, axe only sees the one selected by
default.

**`rhythm`.** The case that originated it: a rule that does not add up the
spacing of two consecutive bands of the same background, applied to a page that
paints its band with its own class instead of declaring it, and that loses the
spacing exactly where the background changes.

## Why `min-width: 0` and not something else

The default `min-width: auto` of a flex item prevents shrinking, and the
content's minimum width rules. `overflow-x: hidden` on the root masks the problem
on that page and it reappears on any other.

## The gotchas, with their why

- With islands or lazy loading, a fast sweep measures the server markup: the
  same block can give 4,766 px or 1,463 depending on whether it has hydrated.
- On returning to the top, what is at the bottom ends up below the fold and the
  invisible check gives a false positive.
- `node script | head` kills the process with SIGPIPE before it writes, and you
  end up comparing against old data.
- A static server does not warn if the port is already taken: you may be
  measuring another application.
- Some bundlers in development do not reliably recompile the root layout, and
  you would measure the previous state.
- Dynamic chunk loading errors on the first headless render can trigger the
  error boundary; the script warms up twice to avoid it.
- Decorative elements with `position: absolute` inside an `overflow: hidden` are
  false positives; the script already ignores `absolute` and `fixed`.
- A `pkill` by pattern can take your own shell with it.
