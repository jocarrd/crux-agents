"""The images of a page's before and after.

An overview sheet puts desktop, mobile and tablet side by side to see where
something changed; it is too small to read. A detail image per device shows the
same at a size that reads on a phone. In both, the before and the after are
split by the red bar and the regions that changed are boxed in red.
"""

import os

from changes import changes
from PIL import Image, ImageDraw, ImageFont

RED = (220, 38, 38)
GREEN = (22, 163, 74)
INK = (17, 24, 39)
GREY = (90, 100, 114)
PAD_COLOUR = (241, 245, 249)
BAR = 10
RULE = 28
MARGIN = 28
HEAD = 150
DESKTOP, MOBILE, TABLET = 0, 1, 2
DESKTOP_FROM = 1000
TABLET_FROM = 600
OVERVIEW_PANEL = {DESKTOP: 640, MOBILE: 260, TABLET: 340}
DETAIL_SHARE = {DESKTOP: 0.75, MOBILE: 1.0, TABLET: 0.75}
BOX_WIDTH = {"overview": 3, "detail": 3}
BOX_HALO = 2
BOX_PAD = 8
BOX_RADIUS = 6
BADGE = {"overview": 18, "detail": 24}
NOTE_ALL = {"es": "cambia casi todo", "en": "nearly everything changes"}
NOTE_NEW = {"es": "página nueva", "en": "new page"}


def device_rank(width):
    if width >= DESKTOP_FROM:
        return DESKTOP
    return TABLET if width >= TABLET_FROM else MOBILE


def _overlaps(box, others):
    left, top, right, bottom = box
    return any(
        left < o_right and o_left < right and top < o_bottom and o_top < bottom
        for o_left, o_top, o_right, o_bottom in others
    )


def _pad_bottom(image, height):
    if image.height >= height:
        return image
    padded = Image.new("RGB", (image.width, height), PAD_COLOUR)
    padded.paste(image, (0, 0))
    return padded


def prepare(width, before_path, after_path, noise_path=None):
    """Both captures at the same height, padded at the bottom only so their
    tops align, with the boxes of what changed in each."""
    after = Image.open(after_path).convert("RGB")
    if before_path is None:
        return {"width": width, "before": None, "after": after, "marks": ([], []), "whole": False}
    before = Image.open(before_path).convert("RGB")
    in_before, in_after, whole = changes(before, after)
    if noise_path:
        _, unstable, _ = changes(before, Image.open(noise_path).convert("RGB"))
        in_before = [b for b in in_before if not _overlaps(b, unstable)]
        in_after = [b for b in in_after if not _overlaps(b, unstable)]
    height = max(before.height, after.height)
    return {
        "width": width,
        "before": _pad_bottom(before, height),
        "after": _pad_bottom(after, height),
        "marks": (in_before, in_after),
        "whole": whole,
    }


def _box(draw, box, scale, top, weight, panel, number, badge):
    left, y0, right, y1 = (v * scale for v in box)
    edge = weight / 2 + BOX_HALO
    shape = [
        max(edge, left - BOX_PAD),
        y0 - top - BOX_PAD,
        min(panel - edge, right + BOX_PAD),
        y1 - top + BOX_PAD,
    ]
    draw.rounded_rectangle(shape, radius=BOX_RADIUS, outline="white", width=weight + BOX_HALO * 2)
    draw.rounded_rectangle(shape, radius=BOX_RADIUS, outline=RED, width=weight)
    cx = min(max(shape[0], badge / 2 + 2), panel - badge / 2 - 2)
    cy = shape[1]
    draw.ellipse([cx - badge / 2, cy - badge / 2, cx + badge / 2, cy + badge / 2], fill=RED, outline="white", width=2)
    draw.text((cx, cy), str(number), fill="white", font=font(round(badge * 0.62)), anchor="mm")


def _piece(image, panel, top, bottom, marks, weight, badge):
    scale = panel / image.width
    scaled = image.resize((panel, round(image.height * scale)))
    piece = scaled.crop((0, top, panel, min(scaled.height, bottom)))
    pen = ImageDraw.Draw(piece)
    for number, box in enumerate(sorted(marks, key=lambda b: (b[1], b[0])), start=1):
        _box(pen, box, scale, top, weight, panel, number, badge)
    return piece


def font(size):
    for path in (
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
        "/usr/share/fonts/TTF/DejaVuSans-Bold.ttf",
        "/Library/Fonts/Arial Bold.ttf",
    ):
        if os.path.exists(path):
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()


def _label(device, names, lang):
    text = f"{names['devices'][device_rank(device['width'])]} · {device['width']} px"
    if device["whole"]:
        return f"{text} · {NOTE_ALL[lang]}"
    return text


def _pair(canvas, draw, device, x, panel, top, bottom, names, fonts, kind):
    weight, badge = BOX_WIDTH[kind], BADGE[kind]
    before_label, after_label = names["labels"]
    _, _, small = fonts
    if device["before"] is not None:
        draw.text((x, 110), before_label, fill=RED, font=small)
        canvas.paste(
            _piece(device["before"], panel, top, bottom, device["marks"][0], weight, badge),
            (x, HEAD),
        )
        draw.rectangle([x + panel, HEAD - 40, x + panel + BAR - 1, canvas.height - MARGIN], fill=RED)
    after_x = x if device["before"] is None else x + panel + BAR
    label = names["preview"] if device["before"] is None else after_label
    draw.text((after_x, 110), label, fill=GREEN, font=small)
    canvas.paste(
        _piece(device["after"], panel, top, bottom, device["marks"][1], weight, badge),
        (after_x, HEAD),
    )


def _title(title, devices, lang, part, parts):
    if any(d["before"] is None for d in devices):
        title = f"{title} · {NOTE_NEW[lang]}"
    return f"{title} · {part + 1}/{parts}" if parts > 1 else title


def _panel(device, wanted):
    return min(wanted, device["after"].width)


def _span(device, panel):
    return panel if device["before"] is None else panel * 2 + BAR


def _parts(height, chunk):
    parts = max(1, -(-height // chunk))
    if parts > 1 and height - (parts - 1) * chunk < chunk // 5:
        parts -= 1
    return parts


def _save(canvas, path, written):
    canvas.save(path, "WEBP", quality=84, method=6)
    written.append(path)


def overview(devices, out_base, title, names, lang, chunk, fonts):
    devices = sorted(devices, key=lambda d: device_rank(d["width"]))
    big, mid, _ = fonts
    panels = [_panel(d, OVERVIEW_PANEL[device_rank(d["width"])]) for d in devices]
    scaled = [round(d["after"].height * p / d["after"].width) for d, p in zip(devices, panels, strict=True)]
    parts = _parts(max(scaled), chunk)
    width = MARGIN * 2 + sum(_span(d, p) for d, p in zip(devices, panels, strict=True))
    width += RULE * (len(devices) - 1)
    written = []
    for part in range(parts):
        spans = [(-(-h // parts) * part, min(h, -(-h // parts) * (part + 1))) for h in scaled]
        canvas = Image.new("RGB", (width, HEAD + max(b - t for t, b in spans) + MARGIN), "white")
        draw = ImageDraw.Draw(canvas)
        draw.text((MARGIN, 18), _title(title, devices, lang, part, parts), fill=INK, font=big)
        x = MARGIN
        for index, (device, panel, (top, bottom)) in enumerate(zip(devices, panels, spans, strict=True)):
            if index:
                draw.rectangle([x - RULE + 8, 18, x - 8, canvas.height - 8], fill=INK)
            draw.text((x, 70), _label(device, names, lang), fill=GREY, font=mid)
            _pair(canvas, draw, device, x, panel, top, bottom, names, fonts, "overview")
            x += _span(device, panel) + RULE
        _save(canvas, f"{out_base}-{part + 1}.webp", written)
    return written


def detail(device, out_base, title, names, lang, chunk, fonts):
    big, mid, _ = fonts
    panel = _panel(device, round(device["width"] * DETAIL_SHARE[device_rank(device["width"])]))
    height = round(device["after"].height * panel / device["after"].width)
    parts = _parts(height, chunk)
    written = []
    for part in range(parts):
        top = part * chunk
        bottom = height if part == parts - 1 else top + chunk
        canvas = Image.new("RGB", (MARGIN * 2 + _span(device, panel), HEAD + bottom - top + MARGIN), "white")
        draw = ImageDraw.Draw(canvas)
        draw.text((MARGIN, 18), _title(title, [device], lang, part, parts), fill=INK, font=big)
        draw.text((MARGIN, 70), _label(device, names, lang), fill=GREY, font=mid)
        _pair(canvas, draw, device, MARGIN, panel, top, bottom, names, fonts, "detail")
        _save(canvas, f"{out_base}-{part + 1}.webp", written)
    return written
