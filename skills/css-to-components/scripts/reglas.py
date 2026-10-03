#!/usr/bin/env python3
"""Lists every CSS rule that touches a selector, in cascade order.

    python3 reglas.py styles.css "block-name"

The pattern is a regular expression against the selector. Rules are printed
in the order they appear, with the media query that wraps them: the last one
that matches wins.
"""
import re
import sys

if len(sys.argv) != 3:
    sys.exit(__doc__)

path, pattern = sys.argv[1], sys.argv[2]
lines = open(path).read().split("\n")

i = 0
media = []
depth = 0
while i < len(lines):
    stripped = lines[i].strip()

    if stripped.startswith("@media"):
        media.append((stripped.rstrip("{").strip(), depth))
        depth += lines[i].count("{") - lines[i].count("}")
        i += 1
        continue

    if stripped.endswith("{") and not stripped.startswith(("@", "/*")):
        opens = i
        start = i
        while start > 0 and lines[start - 1].strip().endswith(","):
            start -= 1
        sel = " ".join(l.strip() for l in lines[start : opens + 1])[:-1].strip()

        end, d = opens, 0
        while end < len(lines):
            d += lines[end].count("{") - lines[end].count("}")
            end += 1
            if d == 0:
                break

        if re.search(pattern, sel):
            wrapper = f"   [{media[-1][0]}]" if media else ""
            print(f"L{start + 1}{wrapper}")
            for k in range(start, end):
                print("   " + lines[k])
        i = end
        continue

    depth += lines[i].count("{") - lines[i].count("}")
    while media and depth <= media[-1][1]:
        media.pop()
    i += 1
