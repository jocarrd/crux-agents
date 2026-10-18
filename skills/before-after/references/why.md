# Why it is shown this way

The procedure is in `SKILL.md`.

## Why a person

Tests do not see the screen, and gate 7 of `/ship` is passed by the agent. Here
a person approves, and does so from their phone: hence three widths, side-by-side
montages and sections that download well on a phone.

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
