#!/usr/bin/env python3
"""Utilidades para mirar de verdad una salida renderizada.

    inspect.py zoom  <img> <x0> <y0> <x1> <y1> [--out f] [--factor 2]
    inspect.py stack <antes> <ahora> [--box x0 y0 x1 y1] [--out f]
    inspect.py asset <fichero.png|.svg>

`zoom` recorta y amplía: mirar la página entera no sirve para juzgar 2 px.
`stack` apila antes y después: un salto de 1 px es medible pero puede no ser
visible hasta que se ven pegados.
`asset` mide la geometría real de una imagen, que casi nunca coincide con su
caja.
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
    a = Image.open(args.antes)
    b = Image.open(args.ahora)
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
    print(f"{args.out} — arriba antes, abajo ahora")
    return 0


def cmd_asset(args) -> int:
    path = Path(args.file)
    if path.suffix.lower() == ".svg":
        m = re.search(r'viewBox="([^"]+)"', path.read_text())
        if not m:
            print("sin viewBox: la relación de aspecto real no está declarada")
            return 1
        _, _, w, h = (float(v) for v in m.group(1).split())
        print(f"viewBox {w:g}x{h:g} — relación {w / h:.2f}:1")
        print("Métela en una caja con esa relación, o se renderizará más pequeña de lo que crees.")
        return 0

    im = Image.open(path).convert("RGBA")
    bbox = im.getchannel("A").getbbox()
    if bbox is None:
        print("la imagen es completamente transparente")
        return 1
    x0, y0, x1, y1 = bbox
    w, h = im.size
    top, left = y0 / h, x0 / w
    right, bottom = (w - x1) / w, (h - y1) / h
    print(f"caja {w}x{h} · contenido real {x1 - x0}x{y1 - y0} en {bbox}")
    print(f"margen transparente — arriba {top:.0%}  abajo {bottom:.0%}  "
          f"izq {left:.0%}  der {right:.0%}")
    if max(top, bottom, left, right) > 0.05:
        print("Aviso: posicionar o dimensionar este asset por su caja no dará el "
              "resultado esperado. Compensa el margen o recorta el asset.")
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
    s.add_argument("antes"); s.add_argument("ahora")
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
