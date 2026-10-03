---
name: ui-behaviour
description: Check that an interface's controls do something useful and are reachable, not just that they exist and look good. Presses every button from a clean state and measures what changes, walks the interface with the tab key looking for what cannot be reached and for focus traps, and verifies the states that only exist when interacting. Use when you finish a screen with filters, tabs, sortable tables, forms or dialogs; when you inherit an interface you do not know; or when someone asks whether a button does anything ("¿esto sirve para algo?").
---

# ui-behaviour

Visual inspection says whether something **looks** right. This says whether it
**does** something and whether it can be **reached**.

They are different questions and fail separately: a button can have perfect
contrast, the right touch area, and not be wired to anything — or be wired and
not reachable with the keyboard.

## When to use

- You finish a screen with controls: filters, tabs, sorting, pagination, forms,
  dialogs.
- You inherit an interface and want to know what is alive and what is decoration.
- You suspect a specific control: «¿esto sirve para algo?».

## Preconditions

The same as `/visual-test`: the system Chrome, `playwright-core` in a cache
directory, and the application running locally.

## What is checked

Six families. The first three are automated; the last three call for judgement.

**1. That the control does something.** Press and measure what changes.

**2. That it can be reached with the keyboard.** Tab through the interface: every
operable control must receive focus, in an order that follows reading, and with
a visible focus ring. A control that only responds to the mouse does not exist
for half the population.

**3. That dialogs behave.** When opened, focus goes in; while it is open, it does
not escape; `Escape` closes; when closed, focus returns to the control that
opened it. A visually closed dialog that retains focus is a failure.

**4. That the states that only exist when interacting hold up.** Hover, focus,
active, disabled. This is where automatic audits fail: they measure the resting
state. If on hover it fills with colour, the contrast has to be measured
*there*. If only one tab is active at a time, the audit only sees the one that
comes by default and the others may be failing.

**5. That whatever only appears on hover has another way in.** An action revealed
on hover does not exist on a touch screen or with a keyboard.

**6. That empty and error states say something.** Filtering down to zero results,
submitting an incomplete form, cutting the network. The interface must say what
is happening, not stay blank.

## The method for family 1

**List** the visible, enabled controls. **Take a fingerprint** of what the user
would see change —the content of the first rows of each table, their headers,
what carries the active mark, the counters, how many cards there are—; comparing
the whole HTML is no use, because it changes for reasons that do not matter.
**Press, wait, take it again.** Whatever changes no signal is suspicious.
**Investigate the suspects one by one**: that is where the work is.

## The two traps that give false positives

Both have happened to me, and both brought me to the point of reporting bugs that
did not exist.

**Chaining clicks without reloading.** If you press «Oceanía» and then, further
down, another «Oceanía», the second changes nothing — because you were already
in Oceanía. **Reload before each control** you really want to judge. It is slow;
do it only with the suspects from the first pass.

**Ambiguous selectors across components.** A page can have two «Reset» buttons,
one per tool, and a «Rank» that belongs to one table and not the other. If the
selector is not scoped, you press one and measure the other, and conclude that it
does not work. **Always scope to the component's root.**

## What is correctly allowed to change nothing

- A control that is **already active**: the selected tab, the filter in place.
- A **reset with nothing to reset**.
- A control whose effect is **outside the fingerprint** you measure: if it opens a
  dialog, navigates away or changes something you do not observe, widen the
  fingerprint instead of writing it off as dead.

## Usage

```bash
cd ~/.cache/visual-test
node ui-behaviour.mjs sweep    http://localhost:3000/path
node ui-behaviour.mjs probe    http://localhost:3000/path "Reset" --scope .rt-root
node ui-behaviour.mjs keyboard http://localhost:3000/path
```

`sweep` does the quick pass and lists the suspects. `probe` reloads, scopes to
the component and presses a single one twice, showing the fingerprint at each
step — which is how a dead button is told apart from one that coincides with the
default state. `keyboard` tabs through the page and reports the controls that do
not receive focus, those without a visible ring, and order jumps.

For contrast on hover, `/visual-test states`.

## What to report

A control with no effect **is not a bug until you rule out the two traps**. Say
what you pressed, from which state and which signal you looked at. «El botón X
no hace nada» without that is almost always an error by whoever is measuring.

## Related

- `/visual-test` — the other half: that it looks right, fits, has contrast, and
  that no animation leaves content invisible
- `/e2e` — when the flow deserves a test that stays
