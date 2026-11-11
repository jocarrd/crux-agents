"""One sheet per page: desktop, mobile and tablet side by side, each with its
before and after split by the red bar, a dark rule between devices and the
regions that changed circled in red."""

from PIL import Image, ImageDraw

from changes import changes

RED = (220, 38, 38)
GREEN = (22, 163, 74)
INK = (17, 24, 39)
GREY = (90, 100, 114)
BAR = 10
RULE = 28
MARGIN = 28
HEAD = 150
MARK_WIDTH = 6
MARK_PAD = 0.18
MARK_MIN_PX = 36
NOTE_ALL = {"es": "cambia casi todo", "en": "nearly everything changes"}
DESKTOP, MOBILE, TABLET = 0, 1, 2
DESKTOP_FROM = 1000
TABLET_FROM = 600
PANEL = {DESKTOP: 640, MOBILE: 260, TABLET: 340}
WIDE_SHARE = 0.7


def device_rank(width):
    if width >= DESKTOP_FROM:
        return DESKTOP
    return TABLET if width >= TABLET_FROM else MOBILE


def _mark(draw, box, scale, offset_x, offset_y, panel):
    left, top, right, bottom = (v * scale for v in box)
    if right - left > panel * WIDE_SHARE:
        inset = MARK_WIDTH
        shape = [
            offset_x + max(inset, left),
            offset_y + top - inset * 2,
            offset_x + min(panel - inset, right),
            offset_y + bottom + inset * 2,
        ]
        radius = min((shape[3] - shape[1]) / 2, MARK_MIN_PX)
        draw.rounded_rectangle(shape, radius=radius, outline=RED, width=MARK_WIDTH)
        return
    pad_x = max((right - left) * MARK_PAD, MARK_MIN_PX / 2)
    pad_y = max((bottom - top) * MARK_PAD, MARK_MIN_PX / 2)
    draw.ellipse(
        [
            offset_x + left - pad_x,
            offset_y + top - pad_y,
            offset_x + right + pad_x,
            offset_y + bottom + pad_y,
        ],
        outline=RED,
        width=MARK_WIDTH,
    )


def _overlaps(box, others):
    left, top, right, bottom = box
    return any(
        left < r and l < right and top < b and t < bottom for l, t, r, b in others
    )


def _prepare(before_path, after_path, width, noise_path=None):
    before = Image.open(before_path).convert("RGB")
    after = Image.open(after_path).convert("RGB")
    in_before, in_after, whole = changes(before, after)
    if noise_path:
        _, unstable, _ = changes(before, Image.open(noise_path).convert("RGB"))
        in_before = [box for box in in_before if not _overlaps(box, unstable)]
        in_after = [box for box in in_after if not _overlaps(box, unstable)]
    panel = PANEL[device_rank(width)]
    scale = panel / after.width
    return {
        "width": width,
        "panel": panel,
        "scale": scale,
        "before": before.resize((panel, round(before.height * scale))),
        "after": after.resize((panel, round(after.height * scale))),
        "marks": (in_before, in_after),
        "whole": whole,
    }


def compose_sheet(captures, out_base, title, names, lang, chunk, fonts):
    """captures: [(width, before, after, noise or None)]; returns the paths written."""
    devices = sorted(
        (_prepare(b, a, w, n) for w, b, a, n in captures),
        key=lambda d: device_rank(d["width"]),
    )
    big, mid, small = fonts
    tallest = max(max(d["before"].height, d["after"].height) for d in devices)
    parts = max(1, -(-tallest // chunk))
    sheet_width = (
        MARGIN * 2
        + sum(d["panel"] * 2 + BAR for d in devices)
        + RULE * (len(devices) - 1)
    )
    before_label, after_label = names["labels"]
    written = []
    for part in range(parts):
        heights = []
        for d in devices:
            full = max(d["before"].height, d["after"].height)
            step = -(-full // parts)
            d["top"], d["bottom"] = part * step, min(full, (part + 1) * step)
            heights.append(d["bottom"] - d["top"])
        canvas = Image.new("RGB", (sheet_width, HEAD + max(heights) + MARGIN), "white")
        draw = ImageDraw.Draw(canvas)
        heading = f"{title} · {part + 1}/{parts}" if parts > 1 else title
        draw.text((MARGIN, 18), heading, fill=INK, font=big)
        x = MARGIN
        for index, d in enumerate(devices):
            if index:
                draw.rectangle(
                    [x - RULE + 8, 18, x - 8, canvas.height - 8], fill=INK
                )
            label = f"{names['devices'][device_rank(d['width'])]} · {d['width']} px"
            if d["whole"]:
                label += f" · {NOTE_ALL[lang]}"
            draw.text((x, 70), label, fill=GREY, font=mid)
            draw.text((x, 110), before_label, fill=RED, font=small)
            draw.text((x + d["panel"] + BAR, 110), after_label, fill=GREEN, font=small)
            for image, marks, offset in (
                (d["before"], d["marks"][0], x),
                (d["after"], d["marks"][1], x + d["panel"] + BAR),
            ):
                if d["top"] >= image.height:
                    continue
                piece = image.crop(
                    (0, d["top"], d["panel"], min(image.height, d["bottom"]))
                )
                pen = ImageDraw.Draw(piece)
                for box in marks:
                    _mark(pen, box, d["scale"], 0, -d["top"], d["panel"])
                canvas.paste(piece, (offset, HEAD))
            draw.rectangle(
                [x + d["panel"], HEAD - 40, x + d["panel"] + BAR - 1, canvas.height - MARGIN],
                fill=RED,
            )
            x += d["panel"] * 2 + BAR + RULE
        path = f"{out_base}-{part + 1}.webp"
        canvas.save(path, "WEBP", quality=84, method=6)
        written.append(path)
    return written
