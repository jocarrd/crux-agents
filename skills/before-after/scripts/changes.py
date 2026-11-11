"""Finds where a page changed between two captures at the same width.

The rows both captures share at the top and at the bottom are set aside first:
a block inserted in the middle pushes everything below it down, and comparing
pixel against pixel would mark the whole rest of the page. What is left, the
band that really differs, is compared cell by cell and grouped into boxes.
"""

from collections import deque

import numpy as np

CELL = 24
THRESHOLD = 48
MIN_CELLS = 2
MERGE_GAP = 2
MAX_MARKS = 6
WHOLE_PAGE_SHARE = 0.55


def _rgb(image):
    return np.asarray(image.convert("RGB"), dtype=np.int16)


def _row_keys(pixels):
    return [row.tobytes() for row in pixels]


def shared_rows(before, after):
    """How many rows are equal at the top and, after them, at the bottom."""
    a, b = _row_keys(before), _row_keys(after)
    top = 0
    limit = min(len(a), len(b))
    while top < limit and a[top] == b[top]:
        top += 1
    bottom = 0
    while bottom < limit - top and a[len(a) - 1 - bottom] == b[len(b) - 1 - bottom]:
        bottom += 1
    return top, bottom


def _cells(mask):
    rows = -(-mask.shape[0] // CELL)
    cols = -(-mask.shape[1] // CELL)
    padded = np.zeros((rows * CELL, cols * CELL), dtype=bool)
    padded[: mask.shape[0], : mask.shape[1]] = mask
    return padded.reshape(rows, CELL, cols, CELL).any(axis=(1, 3))


def _grow(grid, steps):
    grown = grid.copy()
    for _ in range(steps):
        shifted = grown.copy()
        shifted[1:] |= grown[:-1]
        shifted[:-1] |= grown[1:]
        shifted[:, 1:] |= grown[:, :-1]
        shifted[:, :-1] |= grown[:, 1:]
        grown = shifted
    return grown


def _boxes(grid):
    seen = np.zeros_like(grid)
    boxes = []
    for r, c in zip(*np.nonzero(grid), strict=True):
        if seen[r, c]:
            continue
        queue = deque([(r, c)])
        seen[r, c] = True
        cells = 0
        top, left, bottom, right = r, c, r, c
        while queue:
            y, x = queue.popleft()
            cells += 1
            top, left = min(top, y), min(left, x)
            bottom, right = max(bottom, y), max(right, x)
            for ny, nx in ((y - 1, x), (y + 1, x), (y, x - 1), (y, x + 1)):
                if 0 <= ny < grid.shape[0] and 0 <= nx < grid.shape[1]:
                    if grid[ny, nx] and not seen[ny, nx]:
                        seen[ny, nx] = True
                        queue.append((ny, nx))
        boxes.append((cells, top, left, bottom, right))
    return boxes


def changes(before, after):
    """Boxes (left, top, right, bottom) in pixels of each capture, and whether
    nearly everything changed, in which case marking boxes says nothing."""
    a, b = _rgb(before), _rgb(after)
    if a.shape[1] != b.shape[1]:
        raise ValueError("both captures must have the same width")
    top, bottom = shared_rows(a, b)
    band_a = a[top : a.shape[0] - bottom]
    band_b = b[top : b.shape[0] - bottom]
    if band_a.shape[0] == 0 and band_b.shape[0] == 0:
        return [], [], False
    common = min(band_a.shape[0], band_b.shape[0])
    longest = max(band_a.shape[0], band_b.shape[0])
    mask = np.zeros((longest, a.shape[1]), dtype=bool)
    if common:
        diff = np.abs(band_a[:common] - band_b[:common]).sum(axis=2)
        mask[:common] = diff > THRESHOLD
    if longest > common:
        mask[common:] = True
    grid = _grow(_cells(mask), MERGE_GAP)
    marked = _cells(mask)
    page_cells = _cells(np.ones((max(a.shape[0], b.shape[0]), a.shape[1]), bool)).sum()
    if page_cells and marked.sum() / page_cells > WHOLE_PAGE_SHARE:
        return [], [], True
    found = []
    for _, r0, c0, r1, c1 in _boxes(grid):
        real = marked[r0 : r1 + 1, c0 : c1 + 1].sum()
        if real < MIN_CELLS:
            continue
        found.append((real, r0, c0, r1, c1))
    found.sort(reverse=True)
    boxes = []
    for _, r0, c0, r1, c1 in found[:MAX_MARKS]:
        left, right = c0 * CELL, min(a.shape[1], (c1 + 1) * CELL)
        y0, y1 = r0 * CELL, (r1 + 1) * CELL
        boxes.append((left, top + y0, right, top + y1))
    in_before = [
        (left, y0, right, min(y1, top + band_a.shape[0]))
        for left, y0, right, y1 in boxes
        if y0 < top + band_a.shape[0]
    ]
    in_after = [
        (left, y0, right, min(y1, top + band_b.shape[0]))
        for left, y0, right, y1 in boxes
        if y0 < top + band_b.shape[0]
    ]
    return in_before, in_after, False

