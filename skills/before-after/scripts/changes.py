"""Finds where a page changed between two captures at the same width.

The rows of both captures are paired the way a patience diff pairs lines: rows
that are unique in both are anchors, kept in the order they agree on, and
between two anchors what is equal at the top and at the bottom is paired too.
Blank rows are never anchors, so a stretch moved down by something above it is
still paired. Only what has no pair is compared: a stretch replaced by another
is compared pixel by pixel, and the rows one capture has of more are marked
where they have content. The marks are grouped into cells and boxes.
"""

from bisect import bisect_left
from collections import Counter, deque

import numpy as np

CELL = 24
THRESHOLD = 48
MIN_CELLS = 2
MERGE_GAP = 2
MAX_MARKS = 6
WHOLE_PAGE_SHARE = 0.55
BLOCK = 8
BLOCK_THRESHOLD = 30
NUDGE = 1
MIN_THICKNESS_PX = 12


def _rgb(image):
    return np.asarray(image.convert("RGB"), dtype=np.int16)


def _keys(pixels):
    return [row.tobytes() for row in pixels]


def _block_means(pixels):
    rows = pixels.shape[0] // BLOCK * BLOCK
    cols = pixels.shape[1] // BLOCK * BLOCK
    trimmed = pixels[:rows, :cols].astype(np.float32)
    return trimmed.reshape(rows // BLOCK, BLOCK, cols // BLOCK, BLOCK, 3).mean(axis=(1, 3))


def _differs(first, second):
    """Where two stretches differ, ignoring what a layout shift of a fraction of
    a pixel does: an image resampled differently, an edge one pixel lower.
    Blocks are compared by their mean colour, at the closest of nine nudges."""
    mask = np.zeros(first.shape[:2], dtype=bool)
    reference = _block_means(first)
    nearest = None
    for dy in (-NUDGE, 0, NUDGE):
        for dx in (-NUDGE, 0, NUDGE):
            moved = np.roll(second, (dy, dx), axis=(0, 1))
            gap = np.abs(reference - _block_means(moved)).sum(axis=2)
            nearest = gap if nearest is None else np.minimum(nearest, gap)
    means = nearest > BLOCK_THRESHOLD
    blocks = np.repeat(np.repeat(means, BLOCK, axis=0), BLOCK, axis=1)
    mask[: blocks.shape[0], : blocks.shape[1]] = blocks
    return mask


def _content(pixels):
    return np.abs(pixels - pixels[:, :1]).sum(axis=2) > THRESHOLD


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


def _groups(grid):
    seen = np.zeros_like(grid)
    groups = []
    for r, c in zip(*np.nonzero(grid), strict=True):
        if seen[r, c]:
            continue
        queue = deque([(r, c)])
        seen[r, c] = True
        top, left, bottom, right = r, c, r, c
        while queue:
            y, x = queue.popleft()
            top, left = min(top, y), min(left, x)
            bottom, right = max(bottom, y), max(right, x)
            for ny, nx in ((y - 1, x), (y + 1, x), (y, x - 1), (y, x + 1)):
                inside = 0 <= ny < grid.shape[0] and 0 <= nx < grid.shape[1]
                if inside and grid[ny, nx] and not seen[ny, nx]:
                    seen[ny, nx] = True
                    queue.append((ny, nx))
        groups.append((top, left, bottom, right))
    return groups


def _boxes(mask, width):
    marked = _cells(mask)
    found = []
    for g0, h0, g1, h1 in _groups(_grow(marked, MERGE_GAP)):
        inside = marked[g0 : g1 + 1, h0 : h1 + 1]
        real = inside.sum()
        if real < MIN_CELLS:
            continue
        rows, cols = np.nonzero(inside)
        found.append((real, g0 + rows.min(), h0 + cols.min(), g0 + rows.max(), h0 + cols.max()))
    boxes = []
    for _, r0, c0, r1, c1 in sorted(found, reverse=True):
        box = (c0 * CELL, r0 * CELL, min(width, (c1 + 1) * CELL), min(mask.shape[0], (r1 + 1) * CELL))
        left, top, right, bottom = box
        if mask[top:bottom, left:right].any(axis=1).sum() >= MIN_THICKNESS_PX:
            boxes.append(box)
    return boxes[:MAX_MARKS]


def _anchors(ka, kb):
    count_a, count_b = Counter(ka), Counter(kb)
    where_b = {key: j for j, key in enumerate(kb) if count_b[key] == 1}
    pairs = [(i, where_b[key]) for i, key in enumerate(ka) if count_a[key] == 1 and key in where_b]
    tails, tail_at, previous = [], [], [None] * len(pairs)
    for n, (_, j) in enumerate(pairs):
        k = bisect_left(tails, j)
        if k == len(tails):
            tails.append(j)
            tail_at.append(n)
        else:
            tails[k] = j
            tail_at[k] = n
        previous[n] = tail_at[k - 1] if k else None
    chain = []
    n = tail_at[-1] if tail_at else None
    while n is not None:
        chain.append(pairs[n])
        n = previous[n]
    return chain[::-1]


def _unpaired(ka, kb):
    """Stretches (i0, i1, j0, j1) of rows that have no pair in the other capture."""
    stretches = []
    edges = [(-1, -1), *_anchors(ka, kb), (len(ka), len(kb))]
    for (pa, pb), (na, nb) in zip(edges, edges[1:], strict=False):
        i0, i1, j0, j1 = pa + 1, na, pb + 1, nb
        while i0 < i1 and j0 < j1 and ka[i0] == kb[j0]:
            i0, j0 = i0 + 1, j0 + 1
        while i0 < i1 and j0 < j1 and ka[i1 - 1] == kb[j1 - 1]:
            i1, j1 = i1 - 1, j1 - 1
        if i0 < i1 or j0 < j1:
            stretches.append((i0, i1, j0, j1))
    return stretches


def changes(before, after):
    """Boxes (left, top, right, bottom) in pixels of each capture, and whether
    nearly everything changed, in which case boxing it says nothing."""
    a, b = _rgb(before), _rgb(after)
    if a.shape[1] != b.shape[1]:
        raise ValueError("both captures must have the same width")
    mask_a = np.zeros(a.shape[:2], dtype=bool)
    mask_b = np.zeros(b.shape[:2], dtype=bool)
    for i0, i1, j0, j1 in _unpaired(_keys(a), _keys(b)):
        common = min(i1 - i0, j1 - j0)
        if common:
            diff = _differs(a[i0 : i0 + common], b[j0 : j0 + common])
            mask_a[i0 : i0 + common] |= diff
            mask_b[j0 : j0 + common] |= diff
        if i1 - i0 > common:
            mask_a[i0 + common : i1] |= _content(a[i0 + common : i1])
        if j1 - j0 > common:
            mask_b[j0 + common : j1] |= _content(b[j0 + common : j1])
    changed = max(_cells(mask_a).mean(), _cells(mask_b).mean())
    if changed > WHOLE_PAGE_SHARE:
        return [], [], True
    return _boxes(mask_a, a.shape[1]), _boxes(mask_b, b.shape[1]), False


def anchors(before, after):
    """Rows paired across both captures, (before row, after row), in order."""
    return _anchors(_keys(_rgb(before)), _keys(_rgb(after)))


def shift_at(pairs, row, after_side=True):
    """How far a row of one capture moved in the other, from the nearest anchor
    above it; 0 when there is none."""
    offset = 0
    for before_row, after_row in pairs:
        here = after_row if after_side else before_row
        if here > row:
            break
        offset = before_row - after_row if after_side else after_row - before_row
    return offset
