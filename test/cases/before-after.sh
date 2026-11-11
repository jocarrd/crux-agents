#!/usr/bin/env bash

_ba_script() {
  echo "$CRUX_HOME/skills/before-after/scripts/$1"
}

_ba_pages() {
  local dir="$1"
  mkdir -p "$dir/before" "$dir/after" "$dir/noise"
  python3 - "$dir" <<'PY'
import sys
from PIL import Image, ImageDraw
out = sys.argv[1]
for width in (1440, 820, 390):
    page = Image.new("RGB", (width, 1600), (248, 250, 252))
    pen = ImageDraw.Draw(page)
    for y in range(80, 1500, 160):
        pen.rectangle([40, y, width - 40, y + 90], fill=(226, 232, 240))
    page.save(f"{out}/before/home-{width}.png")
    page.save(f"{out}/noise/home-{width}.png")
    page.save(f"{out}/before/same-{width}.png")
    page.save(f"{out}/after/same-{width}.png")
    page.save(f"{out}/noise/same-{width}.png")
    y = 640
    after = Image.new("RGB", (width, 1720), (248, 250, 252))
    after.paste(page.crop((0, 0, width, y)), (0, 0))
    ImageDraw.Draw(after).rectangle([40, y + 10, width - 40, y + 110], fill=(59, 130, 246))
    after.paste(page.crop((0, y, width, 1600)), (0, y + 120))
    ImageDraw.Draw(after).rectangle([width - 120, 100, width - 60, 140], fill=(220, 38, 38))
    after.save(f"{out}/after/home-{width}.png")
PY
}

test_changes_marks_an_inserted_block_without_marking_what_it_pushes_down() {
  sandbox >/dev/null
  local dir="$SB/ba"
  _ba_pages "$dir"
  local out; out="$(cd "$(_ba_script '')" && python3 - "$dir" <<'PY'
import sys
from PIL import Image
from changes import changes
d = sys.argv[1]
_, after, whole = changes(Image.open(f"{d}/before/home-1440.png"), Image.open(f"{d}/after/home-1440.png"))
print("marks", len(after), "whole", whole)
print("lowest", max(b[3] for b in after))
_, same, _ = changes(Image.open(f"{d}/before/same-1440.png"), Image.open(f"{d}/after/same-1440.png"))
print("same", len(same))
PY
)"
  assert_contains "$out" "marks 2 whole False" "the new block and the recoloured button, nothing else"
  assert_contains "$out" "same 0" "an unchanged page has no marks"
  local lowest; lowest="$(echo "$out" | awk '/^lowest/ {print $2}')"
  [ "$lowest" -lt 800 ] || _fail "what the block pushed down was marked too (lowest mark at $lowest px)"
}

test_compose_leaves_an_overview_and_a_readable_image_per_device() {
  sandbox >/dev/null
  local dir="$SB/ba"
  _ba_pages "$dir"
  local out; out="$(python3 "$(_ba_script compose.py)" "$dir" --lang en 2>&1)"
  assert_contains "$out" "01-home-0-overview-1.webp" "an overview of the changed page"
  assert_contains "$out" "01-home-desktop-1.webp" "and its desktop at a size that reads"
  assert_contains "$out" "01-home-mobile-1.webp" "its mobile"
  assert_contains "$out" "01-home-tablet-1.webp" "and its tablet"
  local brief; brief="$(python3 "$(_ba_script compose.py)" "$dir" --lang en --overview-only 2>&1)"
  assert_not_contains "$brief" "home-desktop-1.webp" "--overview-only leaves only the overview"
}

test_a_page_with_no_before_is_a_preview() {
  sandbox >/dev/null
  local dir="$SB/ba"
  _ba_pages "$dir"
  cp "$dir/after/home-390.png" "$dir/after/fresh-390.png"
  local out; out="$(python3 "$(_ba_script compose.py)" "$dir" --lang en 2>&1)"
  assert_contains "$out" "fresh-0-overview-1.webp" "a new page is shown instead of failing"
}
