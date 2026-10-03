#!/usr/bin/env python3
"""Builds the before and after: before on the left, after on the right and a
red bar in the middle, split into chunks that read on a phone.

    python3 compose.py <capture.mjs folder> [--lang es|en] [--chunk 3000]

Pairs before/<name>.png with after/<name>.png and leaves the montages in
<folder>/compare/<name>-<n>.webp. Requires Pillow.
"""

import argparse
import os
import re
import sys

from PIL import Image, ImageDraw, ImageFont

BAR = 14
HEAD = 104
RED = (220, 38, 38)
GREEN = (22, 163, 74)
GREY = (90, 100, 114)
LABELS = {"es": ("ANTES", "DESPUÉS"), "en": ("BEFORE", "AFTER")}
DEVICE = {
    "es": [(600, "móvil"), (1000, "tablet"), (10**6, "escritorio")],
    "en": [(600, "mobile"), (1000, "tablet"), (10**6, "desktop")],
}
# Width of each half by device: mobile at its real size reads on a phone;
# desktop needs more so the text is not dust.
PANEL = [(600, 390), (1000, 450), (10**6, 900)]


def font(size):
    for path in (
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
        "/usr/share/fonts/TTF/DejaVuSans-Bold.ttf",
        "/Library/Fonts/Arial Bold.ttf",
    ):
        if os.path.exists(path):
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()


def pick(table, width):
    return next(value for limit, value in table if width < limit)


def compose(before, after, out_base, label, lang, chunk, width_css):
    panel = pick(PANEL, width_css)
    a = Image.open(before).convert("RGB")
    b = Image.open(after).convert("RGB")
    a = a.resize((panel, round(a.height * panel / a.width)))
    b = b.resize((panel, round(b.height * panel / b.width)))
    total = max(a.height, b.height)
    parts = max(1, -(-total // chunk))
    # A final chunk of a few pixels is just footer: it is added to the previous one.
    if parts > 1 and total - (parts - 1) * chunk < chunk // 5:
        parts -= 1
    big, small = font(34), font(22)
    before_label, after_label = LABELS[lang]
    written = []
    for i in range(parts):
        top = i * chunk
        height = total - top if i == parts - 1 else chunk
        canvas = Image.new("RGB", (panel * 2 + BAR, height + HEAD), "white")
        draw = ImageDraw.Draw(canvas)
        draw.text((20, 18), before_label, fill=RED, font=big)
        draw.text((panel + BAR + 20, 18), after_label, fill=GREEN, font=big)
        for image, x in ((a, 0), (b, panel + BAR)):
            if top < image.height:
                canvas.paste(image.crop((0, top, panel, min(image.height, top + height))), (x, HEAD))
        draw.rectangle([panel, 0, panel + BAR - 1, height + HEAD], fill=RED)
        text = f"{label} · {i + 1}/{parts}"
        width = draw.textlength(text, font=small)
        x0 = max(20, (canvas.width - width) // 2)
        draw.rectangle([x0 - 10, 62, x0 + width + 10, 94], fill="white")
        draw.text((x0, 66), text, fill=GREY, font=small)
        path = f"{out_base}-{i + 1}.webp"
        canvas.save(path, "WEBP", quality=82, method=6)
        written.append(path)
    return written


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("dir")
    parser.add_argument("--lang", default="es", choices=["es", "en"])
    parser.add_argument("--chunk", type=int, default=3000)
    args = parser.parse_args()

    before_dir = os.path.join(args.dir, "before")
    after_dir = os.path.join(args.dir, "after")
    out_dir = os.path.join(args.dir, "compare")
    if not os.path.isdir(before_dir) or not os.path.isdir(after_dir):
        sys.exit(f"missing {before_dir} or {after_dir}: run capture.mjs first")
    os.makedirs(out_dir, exist_ok=True)

    names = sorted(n for n in os.listdir(after_dir) if n.endswith(".png"))
    missing = [n for n in names if not os.path.exists(os.path.join(before_dir, n))]
    if missing:
        sys.exit(f"no before for: {', '.join(missing)}")
    for index, name in enumerate(names, start=1):
        stem = name[:-4]
        match = re.match(r"(.+)-(\d+)$", stem)
        page, width = (match.group(1), int(match.group(2))) if match else (stem, 1440)
        label = f"{page} · {pick(DEVICE[args.lang], width)} {width}px"
        base = os.path.join(out_dir, f"{index:02d}-{stem}")
        for path in compose(
            os.path.join(before_dir, name),
            os.path.join(after_dir, name),
            base,
            label,
            args.lang,
            args.chunk,
            width,
        ):
            size = os.path.getsize(path) // 1024
            print(f"{path} ({size} KB)")


if __name__ == "__main__":
    main()
