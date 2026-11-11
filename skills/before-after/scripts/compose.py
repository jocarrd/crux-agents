#!/usr/bin/env python3
"""Builds the before and after of each page.

    python3 compose.py <capture.mjs folder> [--lang es|en] [--chunk 3000] [--overview-only]

Pairs before/<page>-<width>.png with after/<page>-<width>.png (and with
noise/<page>-<width>.png when the capture ran with --repeat). For each page it
leaves in <folder>/compare/:

    <n>-<page>-0-overview-<part>.webp   desktop, mobile and tablet side by side
    <n>-<page>-<device>-<part>.webp     each device at a size that reads
    <n>-<page>-<device>-<change>-<k>.webp  a close-up of each change

A page with no before is shown as a preview. Requires Pillow and numpy.
"""

import argparse
import json
import os
import re
import sys

from sheet import closeups, detail, device_rank, font, overview, prepare

LABELS = {"es": ("ANTES", "DESPUÉS"), "en": ("BEFORE", "AFTER")}
NAMES = {
    "es": {
        "labels": LABELS["es"],
        "devices": ["escritorio", "móvil", "tablet"],
        "preview": "VISTA PREVIA",
        "overview": "resumen",
        "change": "cambio",
    },
    "en": {
        "labels": LABELS["en"],
        "devices": ["desktop", "mobile", "tablet"],
        "preview": "PREVIEW",
        "overview": "overview",
        "change": "change",
    },
}
FILE_DEVICE = ["desktop", "mobile", "tablet"]


def pages_in(after_dir):
    pages = {}
    for name in sorted(n for n in os.listdir(after_dir) if n.endswith(".png")):
        match = re.match(r"(.+)-(\d+)$", name[:-4])
        page, width = (match.group(1), int(match.group(2))) if match else (name[:-4], 1440)
        pages.setdefault(page, []).append((width, name))
    return pages


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("dir")
    parser.add_argument("--lang", default="es", choices=["es", "en"])
    parser.add_argument("--chunk", type=int, default=3000)
    parser.add_argument("--overview-only", action="store_true")
    args = parser.parse_args()

    before_dir = os.path.join(args.dir, "before")
    after_dir = os.path.join(args.dir, "after")
    noise_dir = os.path.join(args.dir, "noise")
    out_dir = os.path.join(args.dir, "compare")
    if not os.path.isdir(after_dir):
        sys.exit(f"missing {after_dir}: run capture.mjs first")
    os.makedirs(out_dir, exist_ok=True)

    def optional(folder, name):
        path = os.path.join(folder, name)
        return path if os.path.exists(path) else None

    titles_path = os.path.join(args.dir, "pages.json")
    titles = {}
    if os.path.exists(titles_path):
        with open(titles_path, encoding="utf-8") as handle:
            titles = json.load(handle)
    names = NAMES[args.lang]
    fonts = (font(40), font(26), font(24))
    written = []
    for index, (page, shots) in enumerate(sorted(pages_in(after_dir).items()), start=1):
        devices = [
            prepare(
                width,
                optional(before_dir, name),
                os.path.join(after_dir, name),
                optional(noise_dir, name),
            )
            for width, name in shots
        ]
        base = os.path.join(out_dir, f"{index:02d}-{page}")
        title = titles.get(page, page)
        written += overview(
            devices, f"{base}-0-{names['overview']}", title, names, args.lang, args.chunk, fonts
        )
        if args.overview_only:
            continue
        for device in sorted(devices, key=lambda d: device_rank(d["width"])):
            suffix = FILE_DEVICE[device_rank(device["width"])]
            written += detail(device, f"{base}-{suffix}", title, names, args.lang, args.chunk, fonts)
            written += closeups(
                device, f"{base}-{suffix}-{names['change']}", title, names, args.lang, fonts
            )
    for path in written:
        print(f"{path} ({os.path.getsize(path) // 1024} KB)")


if __name__ == "__main__":
    main()
