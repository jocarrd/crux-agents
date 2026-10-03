#!/usr/bin/env python3
"""Utilities for really looking at a rendered output.

    inspect.py zoom  <img> <x0> <y0> <x1> <y1> [--out f] [--factor 2]
    inspect.py stack <before> <after> [--box x0 y0 x1 y1] [--out f]
    inspect.py asset <file.png|.svg>

`zoom` crops and enlarges: looking at the whole page is no use for judging 2 px.
`stack` stacks before and after: a 1 px jump is measurable but may not be
visible until they are seen side by side.
`asset` measures an image's real geometry, which almost never matches its
box.
"""

import argparse
import re
import sys
from pathlib import Path

from PIL import Image


def cmd_zoom(args) -> int:
    box = (args.x0, args.y0, args.x1, args.y1)
    im = Image.open(args.img).crop(box)
    out = im.resize((im.width * args.factor, im.height * args.factor), Image.LANCZOS)
    out.save(args.out)
    print(f"{args.out} — {out.width}x{out.height} (x{args.factor})")
    return 0


def cmd_stack(args) -> int:
    a = Image.open(args.before)
    b = Image.open(args.after)
    if args.box:
        box = tuple(args.box)
        a, b = a.crop(box), b.crop(box)
    f, gap = args.factor, 30
    a = a.resize((a.width * f, a.height * f), Image.LANCZOS)
    b = b.resize((b.width * f, b.height * f), Image.LANCZOS)
    out = Image.new("RGB", (max(a.width, b.width), a.height + b.height + gap), "white")
    out.paste(a, (0, 0))
    out.paste(b, (0, a.height + gap))
    out.save(args.out)
    print(f"{args.out} — before on top, after below")
    return 0


def cmd_asset(args) -> int:
    path = Path(args.file)
    if path.suffix.lower() == ".svg":
        m = re.search(r'viewBox="([^"]+)"', path.read_text())
        if not m:
            print("no viewBox: the real aspect ratio is not declared")
            return 1
        _, _, w, h = (float(v) for v in m.group(1).split())
        print(f"viewBox {w:g}x{h:g} — ratio {w / h:.2f}:1")
        print("Put it in a box with that ratio, or it will render smaller than you think.")
        return 0

    im = Image.open(path).convert("RGBA")
    bbox = im.getchannel("A").getbbox()
    if bbox is None:
        print("the image is completely transparent")
        return 1
    x0, y0, x1, y1 = bbox
    w, h = im.size
    top, left = y0 / h, x0 / w
    right, bottom = (w - x1) / w, (h - y1) / h
    print(f"box {w}x{h} · real content {x1 - x0}x{y1 - y0} at {bbox}")
    print(f"transparent margin — top {top:.0%}  bottom {bottom:.0%}  "
          f"left {left:.0%}  right {right:.0%}")
    if max(top, bottom, left, right) > 0.05:
        print("Warning: positioning or sizing this asset by its box will not give the "
              "expected result. Compensate for the margin or crop the asset.")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)

    z = sub.add_parser("zoom")
    z.add_argument("img"); z.add_argument("x0", type=int); z.add_argument("y0", type=int)
    z.add_argument("x1", type=int); z.add_argument("y1", type=int)
    z.add_argument("--out", default="zoom.png"); z.add_argument("--factor", type=int, default=2)
    z.set_defaults(func=cmd_zoom)

    s = sub.add_parser("stack")
    s.add_argument("before"); s.add_argument("after")
    s.add_argument("--box", type=int, nargs=4)
    s.add_argument("--out", default="stack.png"); s.add_argument("--factor", type=int, default=2)
    s.set_defaults(func=cmd_stack)

    a = sub.add_parser("asset")
    a.add_argument("file")
    a.set_defaults(func=cmd_asset)

    args = ap.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
