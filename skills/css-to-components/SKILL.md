---
name: css-to-components
description: Move styles from a global CSS sheet to the components that use them without changing the design by a single pixel, measuring the geometry before and after instead of comparing screenshots. Use when a global CSS file has grown into the place where the look is really decided, when you want to adopt utilities or a design system on an interface that already exists, or when asked to tidy the CSS "sin tocar el diseño".
---

# From global CSS to components

Move styles without anything shifting. Success is measured by **the computed
values being the same** before and after.

## When to use

- A global sheet concentrates the application's look and grows on its own.
- You want to adopt utilities or a design system on an existing interface.
- The request explicitly says "sin cambiar el diseño".

## The rule that holds it up

**Measure numbers, not pixels.**

Comparing screenshots seems the obvious verification and is the one that wastes
the most time. It gives reds for things that are not the change:

- **Content that varies by itself**: lists that paginate according to the
  available height, records that grow with use, any screen with live data.
- **Animations**: a looping animation prevents two captures from matching.
- **Browser preferences**: a headless browser can start with high contrast or
  reduced motion enabled, and then a mode nobody sees is being compared.
- **Legitimate fixes** requested along the way: as soon as one goes in, the
  references expire and the rest of the reds stop meaning anything.

Measuring the computed geometry does not fail for any of that, and when it fails
it says which property moved.

## The procedure

### 1. Measure the original

Before writing a single class, and at the widths where the design changes
(typically a wide one, an intermediate one and a mobile one):

```js
const caja = (sel) => {
  const el = document.querySelector(sel);
  const r = el.getBoundingClientRect();
  return [r.x, r.y, r.width, r.height].map(Math.round).join(",");
};
```

Also save the properties that give shape: `display`, `position`, `padding`,
`minHeight`, `gridTemplateColumns`, `borderRadius`, `zIndex`. That list is the
contract.

### 2. Find out the effective value

**The value that rules is not the first one that appears in the file.** It is
common for a long sheet to have, at the end, a block that redeclares components
already defined above and overrides them. Migrating the first produces a silent
change.

The script `scripts/reglas.py` lists **all** the rules that touch a selector, in
order and with the media query wrapping them:

```bash
python3 scripts/reglas.py path/to/file.css "block-name"
```

### 3. Translate

Copy the values as they are. **This is not the time to unify**: a stray size
stays stray, with its name, and is noted. Unifying is another job and another
decision, almost always a design one and not a development one.

Responsive breakpoints are translated literally (`max-[900px]:`) even if they do
not match the framework's. Changing them moves the design.

### 4. Remove the rules

Only those of the migrated block, and careful with the **grouped selector**:

```css
.cabecera-pagina p,
.cabecera-panel p { ... }
```

It is a single rule that serves two classes. Deleting it whole when migrating one
leaves the other without style. When the selector is mixed it is **pruned**: the
migrated parts are removed and the live ones kept.

### 5. Measure again

Same script, same widths. The numbers have to match. If they do not, the one
that is off says where to look.

### 6. If it has to be undone

**Always with `git checkout`.** Reinserting rules by hand changes the cascade
order even if the content is identical, and silently breaks screens. Deleting is
safe and reversible; rebuilding by hand is not.

## Before starting, check two things

**That the design system's classes really apply.** A syntax from an earlier
version of the framework may generate no rule at all, and then the global CSS is
the only thing painting. It is checked by looking for the utility in the
compiled sheet, not in the source code.

**Which element rules reach the block.** A selector like `.contenedor h1` has
more specificity than any utility and always beats it. Either that rule is moved
out to the components —which affects the whole application at once— or the
concrete case needs to be forced, and that is noted as an exception.

## What is not migrated

- The printed-page geometry (`@page`) and font declarations: they have no
  utility form.
- Resets that apply to the whole tree (`*`, `prefers-reduced-motion`,
  `prefers-contrast`).
- What serves as a **hook** for another layer: if the print sheet selects
  elements by their class, removing the class from them breaks it. Before
  migrating, that class list is replaced by a single hook applied to the
  containers.

The goal is not zero CSS, which would be a silly target. It is **zero CSS that
competes with the design system**: a printed-page rule competes with nothing; a
font size decided five hundred lines away from the component that uses it, does.

## When finished

What is left is an inventory that could not be made before: all the stray values
the sheet was hiding, now with name and location. Sizes off the scale,
intermediate weights, hand-written shadows. **That inventory is the material for
the conversation with design**, and it is the part that truly unifies the system.

## Related

- `/visual-test` — visual inspection and accessibility audit
- `/visual-diff` — measure against a design reference
- `/root-cause` — when a value does not match and it is not known why
