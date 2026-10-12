---
name: ui-tells
description: Measure on the rendered page the markers that give away a model-generated interface: grids of three identical cards, small-caps eyebrows everywhere, the middle dot as a universal separator, browser windows drawn with divs, round filler figures and brochure verbs. Separates objective failures, which get fixed, from hints, which are the designer's judgement. Use when asked to iterate on or improve an already-built interface, when someone says a screen «parece hecha por IA», «queda genérica» or «parece una plantilla», or before showing a page to an outsider.
---

# ui-tells

A generated interface is recognised by its shape before its content, just like a
generated text. The markers are few, concrete and can be counted. This skill
measures them on the already-rendered page, which is where they are seen.

It is the sibling of `prose-check` for screens, and shares its main rule: **count
and locate, do not fix**. Deciding whether each case is surplus is up to you.

## When to use

- You are asked to iterate on or polish an interface that already exists.
- Someone says a screen «parece hecha por IA», «queda muy genérica» or «parece
  una plantilla».
- Before showing a page to a client or publishing it.

## When not to use

- **As an automatic gate.** Do not put it in `quality.gate`: it would run on
  every `crux ship` and you would end up fighting it on changes that do not
  touch the interface. It is invoked by hand, when it applies.
- For accessibility or horizontal scroll. That is `visual-test`, which runs
  axe-core for real.
- To check that controls do something. That is `ui-behaviour`.
- To decide the design direction. This measures, it does not design.

## Preconditions

The system Chrome and `playwright-core` in the directory you run from. Same as
`visual-test`:

```bash
npm i playwright-core
export CHROME_BIN=/usr/bin/google-chrome   # if it is not at the usual path
```

The page has to be served, locally or in production.

## Usage

```bash
node scripts/ui-tells.mjs check <url> [url...]   # the count
node scripts/ui-tells.mjs detail <url>            # each case with its text
```

It exits with code 1 if there is any objective failure, so it works inside a
script if you ever want to chain it.

## The two groups, and why they are separate

**Objective failures.** They do not depend on anyone's taste: either the
headline fits on the first screen or it does not.

| Marker | Why it is a failure |
| ------ | ------------------- |
| Em dash in visible text | The same tic `prose-check` catches, here in the interface |
| Headline or call to action outside the first screen | Whoever arrives does not see what this is or what to do |
| Navigation over 80px or on two lines | It eats the screen and shows the width was not thought through |
| Button label split over two lines | Reads badly and usually means the text is long |
| `100vh` instead of `100dvh` | On mobile the content jumps when the address bar hides |

**Hints.** They tell something real, but it may be exactly what the content
calls for. They are reported separately and do not score.

Grid of three identical columns, density of small-caps eyebrows, lines with more
than one middle dot, numbered eyebrows (`001 · Capabilities`), browser windows
drawn with divs with no image inside, «scroll» texts, version labels on the
first screen, filler names (Acme, John Doe, Lorem), falsely round figures and
brochure verbs (impulsar, potenciar, unleash, seamless).

That separation is the same one `prose-check` makes with the em dash and the
colon, and for the same reason: an automatic measurement cannot tell a punchline
from an explanation.

## How to read the result

The load is the objective failures. **Zero is normal**, and anything above it is
fixed before delivering.

Hints have no threshold. They are for looking twice: if the front page has five
grids of three identical cards, the problem is probably that all the sections
look like each other, and not any one of them on its own.

## Gotchas

Three false positives already solved in the script (how and why, in
`<this-skill-directory>/references/por-que.md`): do not reintroduce the height
comparison for split labels, the fake window with an image inside or navigation
rows by exact coordinate. The `100vh` check only sees the domain's own CSS.

## Anti-patterns

**Turning the hints into rules.** If you start banning three-column grids
everywhere, you have swapped one generic design for another.

**Measuring without looking.** The skill does not see the composition, which is
often the real reason something «looks AI-made». Run it, but open the page.

**Adopting someone else's aesthetic.** The thresholds here are neutral on
purpose. The ones that depend on style (typefaces, palettes, symmetry) go in
each project's conventions, not in the kernel.

## Related

- `prose-check` — the same method for text.
- `visual-test` — real accessibility, horizontal scroll, contrast.
- `ui-behaviour` — that controls do something.
- `render-loop` — iterate on a rendered output.
