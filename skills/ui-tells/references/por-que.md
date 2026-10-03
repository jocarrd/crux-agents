# The false positives and where this comes from

The procedure is in `SKILL.md`.

## The false positives that were hard to remove

The three false positives that were hard to remove, so they are not
reintroduced:

**Split label.** Comparing the button's height with that of its line flags every
navigation link, because the vertical padding makes them taller. The only thing
that distinguishes a split text is counting the rectangles of a `Range` over the
text node.

**Fake window.** Three circles in a row is a window's chrome, but a frame around
**a real screenshot** is legitimate and very common. It only counts if there is
no `img`, `canvas`, `video` or `picture` inside.

**Two-row navigation.** Grouping by the exact vertical coordinate separates links
that are aligned within two pixels of each other. Two links are on different rows
only if they are separated by more than half a link's height.

And a limitation: stylesheets from another domain cannot be read from the page
because of CORS, so the `100vh` check only sees its own CSS.


## Where it comes from

The markers are taken from [taste-skill](https://github.com/Leonxlnx/taste-skill)
(MIT), specifically from its AI Tells section and its Pre-Flight Check. From its
list only those that are neutral with respect to style were taken: that skill's
aesthetic prescriptions (specific typefaces, asymmetry by default, banning pure
black) were deliberately left out, because each project has its own language and
the kernel must not impose one.
