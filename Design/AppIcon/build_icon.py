#!/usr/bin/env python3
"""Generates vector assets + icon.json for the Translate app icon, builds the .icon, renders previews."""
import json, os, subprocess, sys, pathlib

HERE = pathlib.Path(__file__).resolve().parent
OUT_ASSETS = HERE / "assets"; OUT_ASSETS.mkdir(exist_ok=True)
SCRIPTS = pathlib.Path(sys.argv[1])  # icon skill scripts dir
ICON_OUT = pathlib.Path(sys.argv[2]) # target .icon path
PREVIEW = HERE / "preview"; PREVIEW.mkdir(exist_ok=True)

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

files = {
    "a-bubble.svg": svg(f'<path fill="#000000" d="{a_path}"/>'),
    "a-border.svg": svg(f'<path fill="none" stroke="url(#ga)" stroke-width="{STROKE}" stroke-linejoin="round" d="{a_path}"/>',
                        gradient_defs("ga", A["x0"], A["y0"], A["x0"]+A["w"], A["y0"]+A["h"]+100)),
    "a-glyph.svg": glyph_svg(HERE / "glyph-A.json", 246, A["x0"] + A["w"]/2, A["y0"] + A["h"]/2 + 4),
    "zh-bubble.svg": svg(f'<path fill="#000000" d="{z_path}"/>'),
    "zh-border.svg": svg(f'<path fill="none" stroke="url(#gz)" stroke-width="{STROKE}" stroke-linejoin="round" d="{z_path}"/>',
                         gradient_defs("gz", Z["x0"], Z["y0"], Z["x0"]+Z["w"], Z["y0"]+Z["h"]+100)),
    "zh-glyph.svg": glyph_svg(HERE / "glyph-wen.json", 250, Z["x0"] + Z["w"]/2, Z["y0"] + Z["h"]/2 - 2),
}
for name, content in files.items():
    (OUT_ASSETS / name).write_text(content)

WHITE = "display-p3:1.00000,1.00000,1.00000,1.00000"
INK = "display-p3:0.11000,0.10000,0.30000,1.00000"
DARK_BUBBLE = "display-p3:0.12000,0.12000,0.26000,1.00000"

icon = {
    "color-space-for-untagged-svg-colors": "display-p3",
    "fill-specializations": [
        {"value": {"linear-gradient": ["display-p3:0.44000,0.40000,1.00000,1.00000", "display-p3:0.22000,0.12000,0.66000,1.00000"]}},
        {"appearance": "dark", "value": {"linear-gradient": ["display-p3:0.24000,0.20000,0.62000,1.00000", "display-p3:0.08000,0.05000,0.30000,1.00000"]}},
    ],
    "groups": [
        {
            "name": "chinese bubble",
            "lighting": "individual",
            "specular": True,
            "blur-material": 0.5,
            "layers": [
                {"name": "zh-glyph", "image-name": "zh-glyph.svg", "fill": {"solid": WHITE}, "glass": False},
                {"name": "zh-border", "image-name": "zh-border.svg", "glass": False},
                {"name": "zh-bubble", "image-name": "zh-bubble.svg", "fill": {"solid": DARK_BUBBLE}, "glass": True},
            ],
            "shadow": {"kind": "neutral", "opacity": 0.5},
            "translucency": {"enabled": True, "value": 0.7},
        },
        {
            "name": "latin bubble",
            "lighting": "individual",
            "specular": True,
            "blur-material": 0.5,
            "layers": [
                {"name": "a-glyph", "image-name": "a-glyph.svg", "fill": {"solid": INK}, "glass": False},
                {"name": "a-border", "image-name": "a-border.svg", "glass": False},
                {"name": "a-bubble", "image-name": "a-bubble.svg", "fill": {"solid": WHITE}, "glass": True},
            ],
            "shadow": {"kind": "neutral", "opacity": 0.5},
            "translucency": {"enabled": True, "value": 0.25},
        },
    ],
    "supported-platforms": {"squares": "shared"},
}
(HERE / "icon.json").write_text(json.dumps(icon, indent=2))

cmd = ["uv", "run", "python", "create_icon.py", "--output", str(ICON_OUT), "--icon", str(HERE / "icon.json"), "--force"]
for name in files: cmd += ["--asset", f"{name}={OUT_ASSETS / name}"]
subprocess.run(cmd, cwd=SCRIPTS, check=True)
subprocess.run(["uv", "run", "python", "validate_icon.py", str(ICON_OUT)], cwd=SCRIPTS, check=True)

ictool = pathlib.Path(subprocess.check_output(["xcode-select", "-p"]).decode().strip()).parent / "Applications/Icon Composer.app/Contents/Executables/ictool"
for platform, rendition in [("macOS", "Default"), ("macOS", "Dark"), ("iOS", "Default"), ("iOS", "Dark"), ("iOS", "ClearLight"), ("iOS", "TintedDark")]:
    out = PREVIEW / f"{platform}-{rendition}.png"
    subprocess.run([str(ictool), str(ICON_OUT), "--export-image", "--output-file", str(out), "--platform", platform,
                    "--rendition", rendition, "--width", "512", "--height", "512", "--scale", "2"], check=True)
    print("rendered", out)
