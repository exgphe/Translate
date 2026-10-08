"""Shared geometry and colors for the Translate app icon (Icon Composer and visionOS)."""
import json, pathlib

HERE = pathlib.Path(__file__).resolve().parent

CANVAS = 1024
STROKE = 22

def bubble_path(x0, y0, w, h, r, tail_side):
    """Rounded rectangle with a speech tail on the bottom-left or bottom-right."""
    x1, y1 = x0 + w, y0 + h
    tw, tip_dx, tip_dy, ty = 150, 34, 84, 128
    if tail_side == "left":
        return (f"M{x0+r} {y0} H{x1-r} A{r} {r} 0 0 1 {x1} {y0+r} V{y1-r} A{r} {r} 0 0 1 {x1-r} {y1} "
                f"H{x0+tw} C{x0+100} {y1+4} {x0+62} {y1+52} {x0+tip_dx} {y1+tip_dy} "
                f"C{x0+14} {y1+30} {x0} {y1-20} {x0} {y1-ty} V{y0+r} A{r} {r} 0 0 1 {x0+r} {y0} Z")
    else:
        return (f"M{x0+r} {y0} H{x1-r} A{r} {r} 0 0 1 {x1} {y0+r} V{y1-ty} "
                f"C{x1} {y1-20} {x1-14} {y1+30} {x1-tip_dx} {y1+tip_dy} "
                f"C{x1-62} {y1+52} {x1-100} {y1+4} {x1-tw} {y1} H{x0+r} A{r} {r} 0 0 1 {x0} {y1-r} "
                f"V{y0+r} A{r} {r} 0 0 1 {x0+r} {y0} Z")

def svg(body, defs=""):
    return (f'<?xml version="1.0" encoding="UTF-8"?>\n'
            f'<svg xmlns="http://www.w3.org/2000/svg" width="{CANVAS}" height="{CANVAS}" viewBox="0 0 {CANVAS} {CANVAS}">\n'
            f'{defs}{body}\n</svg>\n')

GRADIENT_STOPS = [("0%", "#FF5C8A"), ("35%", "#FFB04D"), ("65%", "#B86BFF"), ("100%", "#3BD4FF")]

def gradient_defs(gid, x1, y1, x2, y2):
    stops = "".join(f'<stop offset="{o}" stop-color="{c}"/>' for o, c in GRADIENT_STOPS)
    return (f'<defs><linearGradient id="{gid}" gradientUnits="userSpaceOnUse" x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}">'
            f'{stops}</linearGradient></defs>\n')

def glyph_path(json_path, target_height, cx, cy, fill="#000000"):
    """A glyph outline scaled to `target_height` and centered on (cx, cy), as an SVG <path>."""
    g = json.loads(pathlib.Path(json_path).read_text())
    scale = target_height / (g["maxY"] - g["minY"])
    gx = (g["minX"] + g["maxX"]) / 2 * scale
    gy = (g["minY"] + g["maxY"]) / 2 * scale
    tx, ty = cx - gx, cy - gy
    return f'<path transform="translate({tx:.2f} {ty:.2f}) scale({scale:.5f})" fill="{fill}" d="{g["d"]}"/>'

def glyph_svg(json_path, target_height, cx, cy):
    g = json.loads(pathlib.Path(json_path).read_text())
    scale = target_height / (g["maxY"] - g["minY"])
    gx = (g["minX"] + g["maxX"]) / 2 * scale
    gy = (g["minY"] + g["maxY"]) / 2 * scale
    tx, ty = cx - gx, cy - gy
    return svg(f'<path transform="translate({tx:.2f} {ty:.2f}) scale({scale:.5f})" fill="#000000" d="{g["d"]}"/>')

# Geometry (1024pt canvas)
A = dict(x0=118, y0=198, w=468, h=436, r=118)
Z = dict(x0=438, y0=372, w=468, h=436, r=118)
a_path = bubble_path(**A, tail_side="left")
z_path = bubble_path(**Z, tail_side="right")

# Glyph placement inside each bubble.
A_GLYPH = (HERE / "glyph-A.json", 246, A["x0"] + A["w"] / 2, A["y0"] + A["h"] / 2 + 4)
Z_GLYPH = (HERE / "glyph-wen.json", 250, Z["x0"] + Z["w"] / 2, Z["y0"] + Z["h"] / 2 - 2)

# Colors, as Display P3 components (Icon Composer treats untagged SVG colors as Display P3).
BACKGROUND_TOP = (0.44, 0.40, 1.00)
BACKGROUND_BOTTOM = (0.22, 0.12, 0.66)
WHITE = (1.00, 1.00, 1.00)
INK = (0.11, 0.10, 0.30)
DARK_BUBBLE = (0.12, 0.12, 0.26)

def hex_color(rgb):
    return "#" + "".join(f"{round(c * 255):02X}" for c in rgb)
