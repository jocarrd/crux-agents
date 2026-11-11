"""The images of a page's before and after.

An overview sheet puts desktop, mobile and tablet side by side to see where
something changed; it is too small to read. A detail image per device shows the
same at a size that reads on a phone. In both, the before and the after are
split by the red bar and the regions that changed are boxed in red.
"""

import os

from changes import changes
from PIL import Image, ImageDraw, ImageFilter, ImageFont

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
BOX_WIDTH = 3
BOX_HALO = 2
BOX_PAD = 8
BOX_RADIUS = 8
VEIL_ALPHA = 95
DARK_PAGE = 90
GLOW_ALPHA = 110
GLOW_WIDTH = 10
GLOW_BLUR = 6
CLOSEUP_MARGIN = 72
CLOSEUP_MAX_WIDTH = 900
CLOSEUP_MAX_HEIGHT = 1100
BADGE = {"overview": 18, "detail": 24}
NOTE_ALL = {"es": "cambia casi todo", "en": "nearly everything changes"}
NOTE_NEW = {"es": "página nueva", "en": "new page"}
NOTE_COUNT = {"es": ("cambio", "cambios"), "en": ("change", "changes")}


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


def ordered(marks):
    return sorted(marks, key=lambda b: (b[1], b[0]))


def _shape(box, scale, top, panel):
    left, y0, right, y1 = (v * scale for v in box)
    edge = BOX_WIDTH + BOX_HALO
    return [
        max(edge, left - BOX_PAD),
        y0 - top - BOX_PAD,
        min(panel - edge, right + BOX_PAD),
        y1 - top + BOX_PAD,
    ]


def _spotlight(piece, shapes):
    """What did not change fades a little, so the eye goes to what did."""
    dark = sum(piece.convert("L").resize((16, 16)).getdata()) / 256 < DARK_PAGE
    veil = Image.new("L", piece.size, VEIL_ALPHA)
    hole = ImageDraw.Draw(veil)
    for shape in shapes:
        hole.rounded_rectangle(shape, radius=BOX_RADIUS, fill=0)
    tint = Image.new("RGB", piece.size, (0, 0, 0) if dark else (255, 255, 255))
    return Image.composite(tint, piece, veil)


def _glow(piece, shapes):
    layer = Image.new("RGBA", piece.size, (0, 0, 0, 0))
    pen = ImageDraw.Draw(layer)
    for shape in shapes:
        pen.rounded_rectangle(shape, radius=BOX_RADIUS, outline=(*RED, GLOW_ALPHA), width=GLOW_WIDTH)
    layer = layer.filter(ImageFilter.GaussianBlur(GLOW_BLUR))
    inside = Image.new("L", piece.size, 255)
    cut = ImageDraw.Draw(inside)
    for shape in shapes:
        cut.rounded_rectangle(shape, radius=BOX_RADIUS, fill=0)
    alpha = Image.composite(layer.getchannel("A"), Image.new("L", piece.size, 0), inside)
    layer.putalpha(alpha)
    return Image.alpha_composite(piece.convert("RGBA"), layer).convert("RGB")


def _badge(pen, shape, number, size, panel):
    text = str(number)
    face = font(round(size * 0.6))
    width = max(size, pen.textlength(text, font=face) + size * 0.6)
    x0 = min(max(shape[0], 2), panel - width - 2)
    y0 = shape[1] - size - 4
    if y0 < 2:
        y0 = shape[1] + 4
        x0 = min(x0 + 4, panel - width - 2)
    pen.rounded_rectangle([x0, y0, x0 + width, y0 + size], radius=size / 2, fill=RED, outline="white", width=2)
    pen.text((x0 + width / 2, y0 + size / 2), text, fill="white", font=face, anchor="mm")


def _piece(image, panel, top, bottom, marks, badge):
    scale = panel / image.width
    scaled = image.resize((panel, round(image.height * scale)), Image.LANCZOS)
    piece = scaled.crop((0, top, panel, min(scaled.height, bottom)))
    marks = ordered(marks)
    if not marks:
        return piece
    shapes = [_shape(box, scale, top, panel) for box in marks]
    piece = _glow(_spotlight(piece, shapes), shapes)
    pen = ImageDraw.Draw(piece)
    for number, shape in enumerate(shapes, start=1):
        pen.rounded_rectangle(shape, radius=BOX_RADIUS, outline="white", width=BOX_WIDTH + BOX_HALO * 2)
        pen.rounded_rectangle(shape, radius=BOX_RADIUS, outline=RED, width=BOX_WIDTH)
        _badge(pen, shape, number, badge, panel)
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
    count = len(device["marks"][1]) or len(device["marks"][0])
    if count:
        one, many = NOTE_COUNT[lang]
        return f"{text} · {count} {one if count == 1 else many}"
    return text


def _pair(canvas, draw, device, x, panel, top, bottom, names, fonts, kind):
    badge = BADGE[kind]
    before_label, after_label = names["labels"]
    _, _, small = fonts
    if device["before"] is not None:
        draw.text((x, 110), before_label, fill=RED, font=small)
        canvas.paste(
            _piece(device["before"], panel, top, bottom, device["marks"][0], badge),
            (x, HEAD),
        )
        draw.rectangle([x + panel, HEAD - 40, x + panel + BAR - 1, canvas.height - MARGIN], fill=RED)
    after_x = x if device["before"] is None else x + panel + BAR
    label = names["preview"] if device["before"] is None else after_label
    draw.text((after_x, 110), label, fill=GREEN, font=small)
    canvas.paste(
        _piece(device["after"], panel, top, bottom, device["marks"][1], badge),
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


def closeups(device, out_base, title, names, lang, fonts):
    """One image per change: the before and the after of that region, cropped
    and at a size where it can be read without looking for it."""
    if device["before"] is None or device["whole"]:
        return []
    big, mid, small = fonts
    before_label, after_label = names["labels"]
    one, _ = NOTE_COUNT[lang]
    before_marks, after_marks = (ordered(m) for m in device["marks"])
    written = []
    for number in range(1, max(len(before_marks), len(after_marks)) + 1):
        pieces = []
        for image, marks, label, colour in (
            (device["before"], before_marks, before_label, RED),
            (device["after"], after_marks, after_label, GREEN),
        ):
            if number <= len(marks):
                left, top, right, bottom = marks[number - 1]
                crop = image.crop((
                    max(0, left - CLOSEUP_MARGIN),
                    max(0, top - CLOSEUP_MARGIN),
                    min(image.width, right + CLOSEUP_MARGIN),
                    min(image.height, bottom + CLOSEUP_MARGIN),
                ))
                scale = min(1, CLOSEUP_MAX_WIDTH / crop.width, CLOSEUP_MAX_HEIGHT / crop.height)
                crop = crop.resize((round(crop.width * scale), round(crop.height * scale)), Image.LANCZOS)
                pieces.append((crop, label, colour))
        width = MARGIN * 2 + sum(c.width for c, _, _ in pieces) + BAR * (len(pieces) - 1) + RULE
        height = HEAD + max(c.height for c, _, _ in pieces) + MARGIN
        canvas = Image.new("RGB", (width, height), "white")
        draw = ImageDraw.Draw(canvas)
        total = max(len(before_marks), len(after_marks))
        draw.text((MARGIN, 18), f"{title} · {one} {number}/{total}", fill=INK, font=big)
        device_name = names["devices"][device_rank(device["width"])]
        draw.text((MARGIN, 70), f"{device_name} · {device['width']} px", fill=GREY, font=mid)
        x = MARGIN
        for index, (crop, label, colour) in enumerate(pieces):
            if index:
                draw.rectangle([x - BAR - RULE // 2, HEAD - 40, x - RULE // 2 - 1, height - MARGIN], fill=RED)
            draw.text((x, 110), label, fill=colour, font=small)
            canvas.paste(crop, (x, HEAD))
            draw.rounded_rectangle(
                [x - 1, HEAD - 1, x + crop.width, HEAD + crop.height],
                radius=4,
                outline=(*RED,) if colour == GREEN else GREY,
                width=2,
            )
            x += crop.width + BAR + RULE
        _save(canvas, f"{out_base}-{number}.webp", written)
    return written
