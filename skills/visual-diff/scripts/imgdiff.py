#!/usr/bin/env python3
"""Mide cuánto se desvía un render respecto a una referencia visual.

    imgdiff.py <actual> <referencia> [opciones]

Acepta PDF (se rasteriza con pdftoppm) o imágenes. Produce, en el directorio
de salida: report.md ordenado por desviación descendente, scores.json y una
superposición por página con el actual en rojo y la referencia en azul.

El desenfoque previo es lo que hace utilizable la comparación entre
renderizadores distintos: sin él, el antialias domina la señal y todo parece
diferente. Con él sobreviven los defectos reales de posición, tamaño y color.
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
        sys.exit(f"pdftoppm no produjo páginas para {path}")
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
            # Una celda casi blanca en ambas no aporta señal: son los márgenes,
            # y sin este filtro inflan la media y esconden los defectos reales.
            if ca.mean() > white_skip and cb.mean() > white_skip:
                continue
            out.append({
                "col": c, "row": r,
                "error": float(np.abs(ca - cb).mean()),
                "box": [x0, y0, x1, y1],
            })
    return out


def label_for(cell: dict, blocks: list[dict], w: int, h: int) -> str | None:
    """Nombra la celda con el bloque semántico que la contiene.

    Un informe que dice "la cabecera está desplazada" es accionable; uno que
    dice "celda 3,7" obliga a ir a mirar el PNG para entender qué pasa.
    """
    cx = (cell["box"][0] + cell["box"][2]) / 2 / w
    cy = (cell["box"][1] + cell["box"][3]) / 2 / h
    for blk in blocks:
        x0, y0, x1, y1 = blk["box"]
        if x0 <= cx <= x1 and y0 <= cy <= y1:
            return blk["name"]
    return None


def overlay(a: np.ndarray, b: np.ndarray) -> Image.Image:
    """Superpone ambas: lo que coincide sale gris neutro, y el desalineo
    aparece como fantasma de color — azul donde solo hay contenido en el
    actual, cálido donde solo lo hay en la referencia."""
    ga = a.mean(axis=2)
    gb = b.mean(axis=2)
    rgb = np.stack([255 - (255 - ga) , 255 - ((255 - ga) + (255 - gb)) / 2, 255 - (255 - gb)], axis=2)
    return Image.fromarray(np.clip(rgb, 0, 255).astype(np.uint8))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("actual")
    ap.add_argument("reference")
    ap.add_argument("--out", default="diff-out")
    ap.add_argument("--grid", default="12x18", help="columnas x filas")
    ap.add_argument("--dpi", type=int, default=150)
    ap.add_argument("--blur", type=float, default=1.5)
    ap.add_argument("--thresh", type=float, default=10.0, help="error de celda que se reporta")
    ap.add_argument("--white-skip", type=float, default=250.0)
    ap.add_argument("--blocks", help="JSON con bloques semánticos en coordenadas 0-1")
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
            print(f"aviso: {len(pages_a)} páginas frente a {len(pages_b)}; se comparan las comunes")

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

    lines = ["# Diff de fidelidad", ""]
    lines += [f"- actual: `{args.actual}`", f"- referencia: `{args.reference}`",
              f"- rejilla {cols}x{rows} · {args.dpi} dpi · blur {args.blur} · umbral {args.thresh}", ""]

    worst_overall = []
    for page in results:
        over = [c for c in page["cells"] if c["error"] >= args.thresh]
        lines.append(f"## Página {page['page']} — error medio {page['mean_error']:.2f}")
        lines.append("")
        if not over:
            lines += ["Sin celdas por encima del umbral.", ""]
            continue
        lines.append("| error | zona | celda |")
        lines.append("| ----- | ---- | ----- |")
        for c in over[:20]:
            lines.append(f"| {c['error']:.1f} | {c['label'] or '—'} | {c['col']},{c['row']} |")
        lines.append("")
        worst_overall += [(c["error"], page["page"], c["label"]) for c in over]

    if worst_overall:
        worst_overall.sort(reverse=True)
        lines += ["## Lo peor, en orden", ""]
        for err, page, label in worst_overall[:10]:
            lines.append(f"- {err:.1f} — página {page}, {label or 'zona sin nombre'}")
        lines.append("")

    (outdir / "report.md").write_text("\n".join(lines))
    print("\n".join(lines[:40]))
    print(f"\nsalida completa en {outdir}/")
    return 1 if worst_overall else 0


if __name__ == "__main__":
    sys.exit(main())
