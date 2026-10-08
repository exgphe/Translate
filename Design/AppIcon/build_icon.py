#!/usr/bin/env python3
"""Generates vector assets + icon.json for the Translate app icon, builds the .icon, renders previews."""
import json, os, subprocess, sys, pathlib

HERE = pathlib.Path(__file__).resolve().parent
OUT_ASSETS = HERE / "assets"; OUT_ASSETS.mkdir(exist_ok=True)
SCRIPTS = pathlib.Path(sys.argv[1])  # icon skill scripts dir
ICON_OUT = pathlib.Path(sys.argv[2]) # target .icon path
PREVIEW = HERE / "preview"; PREVIEW.mkdir(exist_ok=True)

from icon_geometry import *  # noqa: F403  shared with build_vision_icon.py


files = {
    "a-bubble.svg": svg(f'<path fill="#000000" d="{a_path}"/>'),
    "a-border.svg": svg(f'<path fill="none" stroke="url(#ga)" stroke-width="{STROKE}" stroke-linejoin="round" d="{a_path}"/>',
                        gradient_defs("ga", A["x0"], A["y0"], A["x0"]+A["w"], A["y0"]+A["h"]+100)),
    "a-glyph.svg": glyph_svg(*A_GLYPH),
    "zh-bubble.svg": svg(f'<path fill="#000000" d="{z_path}"/>'),
    "zh-border.svg": svg(f'<path fill="none" stroke="url(#gz)" stroke-width="{STROKE}" stroke-linejoin="round" d="{z_path}"/>',
                         gradient_defs("gz", Z["x0"], Z["y0"], Z["x0"]+Z["w"], Z["y0"]+Z["h"]+100)),
    "zh-glyph.svg": glyph_svg(*Z_GLYPH),
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
