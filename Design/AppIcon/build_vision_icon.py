#!/usr/bin/env python3
"""Builds the visionOS app icon: a three-layer solid image stack for the asset catalog.

visionOS does not use Icon Composer documents. Its icon is circular and made of up to three
1024 x 1024 layers that the system separates in depth, adding parallax, shadows and specular
highlights itself. Following the Human Interface Guidelines:
  * Back: fully opaque, fills the square (the system masks it to a circle).
  * Middle and front: transparent except for their element; no baked-in shadows or highlights.
  * Content stays well inside the circle so parallax never pushes it past the edge.

The artwork matches the Icon Composer icon: same gradient, bubbles, borders and glyphs, with the
Chinese bubble in front (slightly translucent, like its glass in the other icon) and the Latin
bubble in the middle.

Usage: python3 build_vision_icon.py <path/to/VisionAppIcon.solidimagestack>
Needs rsvg-convert and Pillow.
"""
import json
import pathlib
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw

from icon_geometry import (A, A_GLYPH, BACKGROUND_BOTTOM, BACKGROUND_TOP, CANVAS, DARK_BUBBLE, HERE, INK, STROKE,
                           WHITE, Z, Z_GLYPH, a_path, glyph_path, gradient_defs, hex_color, svg, z_path)

STACK = pathlib.Path(sys.argv[1]).resolve()
PREVIEW = HERE / "preview"
DISPLAY_P3 = pathlib.Path("/System/Library/ColorSync/Profiles/Display P3.icc").read_bytes()
SAFE_RADIUS = 400          # farthest content pixel from the center, out of a 512 px radius
FRONT_OPACITY = 0.88       # lets the white bubble show faintly through, like the glass version
INFO = {"author": "xcode", "version": 1}


def middle_body(transform):
    border = gradient_defs("ga", A["x0"], A["y0"], A["x0"] + A["w"], A["y0"] + A["h"] + 100)
    body = (f'<g transform="{transform}">'
            f'<path fill="{hex_color(WHITE)}" d="{a_path}"/>'
            f'<path fill="none" stroke="url(#ga)" stroke-width="{STROKE}" stroke-linejoin="round" d="{a_path}"/>'
            f'{glyph_path(*A_GLYPH, fill=hex_color(INK))}</g>')
    return svg(body, border)


def front_body(transform):
    border = gradient_defs("gz", Z["x0"], Z["y0"], Z["x0"] + Z["w"], Z["y0"] + Z["h"] + 100)
    body = (f'<g transform="{transform}">'
            f'<path fill="{hex_color(DARK_BUBBLE)}" fill-opacity="{FRONT_OPACITY}" d="{z_path}"/>'
            f'<path fill="none" stroke="url(#gz)" stroke-width="{STROKE}" stroke-linejoin="round" d="{z_path}"/>'
            f'{glyph_path(*Z_GLYPH, fill=hex_color(WHITE))}</g>')
    return svg(body, border)


def back_body():
    defs = (f'<defs><linearGradient id="bg" gradientUnits="userSpaceOnUse" x1="0" y1="0" x2="0" y2="{CANVAS}">'
            f'<stop offset="0%" stop-color="{hex_color(BACKGROUND_TOP)}"/>'
            f'<stop offset="100%" stop-color="{hex_color(BACKGROUND_BOTTOM)}"/></linearGradient></defs>\n')
    return svg(f'<rect width="{CANVAS}" height="{CANVAS}" fill="url(#bg)"/>', defs)


def render(svg_text):
    """SVG → RGBA image. Color values are passed through unchanged and tagged Display P3 later."""
    with tempfile.TemporaryDirectory() as tmp:
        src, out = pathlib.Path(tmp, "in.svg"), pathlib.Path(tmp, "out.png")
        src.write_text(svg_text)
        subprocess.run(["rsvg-convert", "-w", str(CANVAS), "-h", str(CANVAS), str(src), "-o", str(out)], check=True)
        return Image.open(out).convert("RGBA")


def content_geometry(images):
    """Center of the visible content's bounding box and the farthest visible pixel from it."""
    alpha = images[0].getchannel("A")
    for image in images[1:]:
        alpha = Image.composite(image.getchannel("A"), alpha, image.getchannel("A"))
    left, top, right, bottom = alpha.point(lambda a: 255 if a > 8 else 0).getbbox()
    cx, cy = (left + right) / 2, (top + bottom) / 2
    pixels = alpha.load()
    farthest = max(
        ((x - cx) ** 2 + (y - cy) ** 2) ** 0.5
        for y in range(top, bottom, 2) for x in range(left, right, 2) if pixels[x, y] > 8
    )
    return cx, cy, farthest


def save_layer(image, name):
    layer = STACK / f"{name}.solidimagestacklayer"
    imageset = layer / "Content.imageset"
    imageset.mkdir(parents=True, exist_ok=True)
    filename = f"{name.lower()}.png"
    if name == "Back":
        image = image.convert("RGB")  # opaque layer: no alpha channel at all
    image.save(imageset / filename, icc_profile=DISPLAY_P3, optimize=True)
    (layer / "Contents.json").write_text(json.dumps({"info": INFO}, indent=2) + "\n")
    (imageset / "Contents.json").write_text(json.dumps(
        {"images": [{"filename": filename, "idiom": "vision", "scale": "2x"}], "info": INFO}, indent=2) + "\n")


def main():
    # Pass 1: measure the artwork as drawn for the square icon.
    cx, cy, farthest = content_geometry([render(middle_body("")), render(front_body(""))])
    scale = SAFE_RADIUS / farthest
    transform = f"translate({CANVAS / 2} {CANVAS / 2}) scale({scale:.5f}) translate({-cx:.2f} {-cy:.2f})"
    print(f"content center ({cx:.0f}, {cy:.0f}), farthest {farthest:.0f} px -> scale {scale:.3f}")

    # Pass 2: final layers.
    back = render(back_body())
    middle = render(middle_body(transform))
    front = render(front_body(transform))
    assert back.getchannel("A").getextrema() == (255, 255), "the back layer must be fully opaque"

    STACK.mkdir(parents=True, exist_ok=True)
    (STACK / "Contents.json").write_text(json.dumps({
        "info": INFO,
        "layers": [{"filename": f"{name}.solidimagestacklayer"} for name in ("Front", "Middle", "Back")],
    }, indent=2) + "\n")
    for image, name in ((front, "Front"), (middle, "Middle"), (back, "Back")):
        save_layer(image, name)

    # Preview: flattened and masked to a circle, as on the visionOS Home View (without depth effects).
    PREVIEW.mkdir(exist_ok=True)
    flat = Image.alpha_composite(Image.alpha_composite(back, middle), front)
    mask = Image.new("L", flat.size, 0)
    ImageDraw.Draw(mask).ellipse((0, 0, CANVAS - 1, CANVAS - 1), fill=255)
    circle = Image.new("RGBA", flat.size, (0, 0, 0, 0))
    circle.paste(flat, mask=mask)
    circle.save(PREVIEW / "visionOS.png")
    guide = circle.copy()
    ImageDraw.Draw(guide).ellipse((CANVAS / 2 - SAFE_RADIUS, CANVAS / 2 - SAFE_RADIUS, CANVAS / 2 + SAFE_RADIUS, CANVAS / 2 + SAFE_RADIUS), outline=(255, 255, 255, 160), width=3)
    guide.save(PREVIEW / "visionOS-safe-area.png")
    print(f"wrote {STACK}")


main()
