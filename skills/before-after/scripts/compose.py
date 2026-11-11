#!/usr/bin/env python3
"""Builds the before and after of each page.

    python3 compose.py <capture.mjs folder> [--lang es|en] [--chunk 3000] [--split]

Pairs before/<page>-<width>.png with after/<page>-<width>.png. By default it
leaves one sheet per page in <folder>/compare/<n>-<page>-<part>.webp: desktop,
mobile and tablet side by side, before and after split by a red bar and the
regions that changed circled in red. --split also leaves the old montage per
width. Requires Pillow and numpy.
"""

import argparse
import os
import re
import sys

from PIL import Image, ImageDraw, ImageFont

from sheet import compose_sheet

BAR = 14
HEAD = 104
RED = (220, 38, 38)
GREEN = (22, 163, 74)
GREY = (90, 100, 114)
LABELS = {"es": ("ANTES", "DESPUÉS"), "en": ("BEFORE", "AFTER")}
SHEET_NAMES = {
    "es": {"labels": LABELS["es"], "devices": ["escritorio", "móvil", "tablet"]},
    "en": {"labels": LABELS["en"], "devices": ["desktop", "mobile", "tablet"]},
}
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
    parser.add_argument("--split", action="store_true")
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
    noise_dir = os.path.join(args.dir, "noise")

    def noise_of(name):
        path = os.path.join(noise_dir, name)
        return path if os.path.exists(path) else None

    pages = {}
    for name in names:
        stem = name[:-4]
        match = re.match(r"(.+)-(\d+)$", stem)
        page, width = (match.group(1), int(match.group(2))) if match else (stem, 1440)
        pages.setdefault(page, []).append((width, stem, name))

    written = []
    for index, (page, shots) in enumerate(sorted(pages.items()), start=1):
        written += compose_sheet(
            [
                (
                    w,
                    os.path.join(before_dir, n),
                    os.path.join(after_dir, n),
                    noise_of(n),
                )
                for w, _, n in shots
            ],
            os.path.join(out_dir, f"{index:02d}-{page}"),
            page,
            SHEET_NAMES[args.lang],
            args.lang,
            args.chunk,
            (font(40), font(26), font(24)),
        )
        if not args.split:
            continue
        for width, stem, name in shots:
            label = f"{page} · {pick(DEVICE[args.lang], width)} {width}px"
            written += compose(
                os.path.join(before_dir, name),
                os.path.join(after_dir, name),
                os.path.join(out_dir, f"{index:02d}-{stem}"),
                label,
                args.lang,
                args.chunk,
                width,
            )
    for path in written:
        print(f"{path} ({os.path.getsize(path) // 1024} KB)")

if __name__ == "__main__":
    main()
