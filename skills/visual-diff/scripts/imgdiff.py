#!/usr/bin/env python3
"""Measures how far a render deviates from a visual reference.

    imgdiff.py <actual> <reference> [options]

Accepts PDF (rasterized with pdftoppm) or images. Produces, in the output
directory: report.md sorted by descending deviation, scores.json and a
per-page overlay with the actual in red and the reference in blue.

The prior blur is what makes comparison across different renderers usable:
without it antialiasing dominates the signal and everything looks different.
With it the real defects of position, size and color survive.
"""

import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter


def rasterize(path: Path, dpi: int, workdir: Path, tag: str) -> list[Path]:
    if path.suffix.lower() != ".pdf":
        return [path]
    prefix = workdir / tag
    subprocess.run(
        ["pdftoppm", "-png", "-r", str(dpi), str(path), str(prefix)],
        check=True, capture_output=True,
    )
    pages = sorted(workdir.glob(f"{tag}-*.png"))
    if not pages:
        sys.exit(f"pdftoppm produced no pages for {path}")
    return pages


def load(path: Path, size: tuple[int, int] | None, blur: float) -> np.ndarray:
    im = Image.open(path).convert("RGB")
    if size and im.size != size:
        im = im.resize(size, Image.LANCZOS)
    if blur > 0:
        im = im.filter(ImageFilter.GaussianBlur(blur))
    return np.asarray(im).astype(np.float32)


def cell_scores(a: np.ndarray, b: np.ndarray, cols: int, rows: int,
                white_skip: float) -> list[dict]:
    h, w, _ = a.shape
    out = []
    for r in range(rows):
        for c in range(cols):
            y0, y1 = r * h // rows, (r + 1) * h // rows
            x0, x1 = c * w // cols, (c + 1) * w // cols
            ca, cb = a[y0:y1, x0:x1], b[y0:y1, x0:x1]
            # A cell almost white in both carries no signal: they are margins,
            # and without this filter they inflate the mean and hide the real
            # defects.
            if ca.mean() > white_skip and cb.mean() > white_skip:
                continue
            out.append({
                "col": c, "row": r,
                "error": float(np.abs(ca - cb).mean()),
                "box": [x0, y0, x1, y1],
            })
    return out


def label_for(cell: dict, blocks: list[dict], w: int, h: int) -> str | None:
    """Names the cell with the semantic block that contains it.

    A report that says "the header is shifted" is actionable; one that says
    "cell 3,7" forces you to go look at the PNG to understand what is happening.
    """
    cx = (cell["box"][0] + cell["box"][2]) / 2 / w
    cy = (cell["box"][1] + cell["box"][3]) / 2 / h
    for blk in blocks:
        x0, y0, x1, y1 = blk["box"]
        if x0 <= cx <= x1 and y0 <= cy <= y1:
            return blk["name"]
    return None


def overlay(a: np.ndarray, b: np.ndarray) -> Image.Image:
    """Overlays both: what matches comes out neutral grey, and misalignment
    shows as a colored ghost: blue where only the actual has content, warm
    where only the reference does."""
    ga = a.mean(axis=2)
    gb = b.mean(axis=2)
    rgb = np.stack([255 - (255 - ga) , 255 - ((255 - ga) + (255 - gb)) / 2, 255 - (255 - gb)], axis=2)
    return Image.fromarray(np.clip(rgb, 0, 255).astype(np.uint8))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("actual")
    ap.add_argument("reference")
    ap.add_argument("--out", default="diff-out")
    ap.add_argument("--grid", default="12x18", help="columns x rows")
    ap.add_argument("--dpi", type=int, default=150)
    ap.add_argument("--blur", type=float, default=1.5)
    ap.add_argument("--thresh", type=float, default=10.0, help="cell error that gets reported")
    ap.add_argument("--white-skip", type=float, default=250.0)
    ap.add_argument("--blocks", help="JSON with semantic blocks in 0-1 coordinates")
    args = ap.parse_args()

    cols, rows = (int(n) for n in args.grid.lower().split("x"))
    outdir = Path(args.out)
    outdir.mkdir(parents=True, exist_ok=True)

    blocks = json.loads(Path(args.blocks).read_text()) if args.blocks else []

    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        pages_a = rasterize(Path(args.actual), args.dpi, work, "a")
        pages_b = rasterize(Path(args.reference), args.dpi, work, "b")

        if len(pages_a) != len(pages_b):
            print(f"warning: {len(pages_a)} pages versus {len(pages_b)}; comparing the common ones")

        results = []
        for i, (pa, pb) in enumerate(zip(pages_a, pages_b), start=1):
            ref_size = Image.open(pb).size
            a = load(pa, ref_size, args.blur)
            b = load(pb, ref_size, args.blur)
            h, w, _ = a.shape

            page_blocks = [x for x in blocks if x.get("page", i) == i]
            cells = cell_scores(a, b, cols, rows, args.white_skip)
            for cell in cells:
                cell["label"] = label_for(cell, page_blocks, w, h)

            overlay(a, b).save(outdir / f"overlay-{i}.png")
            results.append({
                "page": i,
                "mean_error": float(np.mean([c["error"] for c in cells])) if cells else 0.0,
                "cells": sorted(cells, key=lambda c: -c["error"]),
            })

    (outdir / "scores.json").write_text(json.dumps(results, indent=2) + "\n")

    lines = ["# Fidelity diff", ""]
    lines += [f"- actual: `{args.actual}`", f"- reference: `{args.reference}`",
              f"- grid {cols}x{rows} · {args.dpi} dpi · blur {args.blur} · threshold {args.thresh}", ""]

    worst_overall = []
    for page in results:
        over = [c for c in page["cells"] if c["error"] >= args.thresh]
        lines.append(f"## Page {page['page']} — mean error {page['mean_error']:.2f}")
        lines.append("")
        if not over:
            lines += ["No cells above the threshold.", ""]
            continue
        lines.append("| error | area | cell |")
        lines.append("| ----- | ---- | ---- |")
        for c in over[:20]:
            lines.append(f"| {c['error']:.1f} | {c['label'] or '—'} | {c['col']},{c['row']} |")
        lines.append("")
        worst_overall += [(c["error"], page["page"], c["label"]) for c in over]

    if worst_overall:
        worst_overall.sort(reverse=True)
        lines += ["## The worst, in order", ""]
        for err, page, label in worst_overall[:10]:
            lines.append(f"- {err:.1f} — page {page}, {label or 'unnamed area'}")
        lines.append("")

    (outdir / "report.md").write_text("\n".join(lines))
    print("\n".join(lines[:40]))
    print(f"\nfull output in {outdir}/")
    return 1 if worst_overall else 0


if __name__ == "__main__":
    sys.exit(main())
