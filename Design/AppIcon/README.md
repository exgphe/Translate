# App icon source

There are two icons built from the same artwork (`icon_geometry.py` holds the shared shapes, glyphs and Display P3 colors):

| Platform | File | Format |
|---|---|---|
| iOS, iPadOS, macOS | `Translate/AppIcon.icon` | Icon Composer 2 package, all-SVG layers |
| visionOS | `Translate/Assets.xcassets/VisionAppIcon.solidimagestack` | Three-layer solid image stack (1024 × 1024 PNGs, Display P3) |

The app target picks the visionOS one with `ASSETCATALOG_COMPILER_APPICON_NAME[sdk=xros*/xrsimulator*] = VisionAppIcon`; other platforms use `AppIcon`.

## Regenerating

```bash
# Glyph outlines (CoreText → SVG path data)
swiftc -O glyph.swift -o glyph
./glyph SFPro-Semibold A 1000 > glyph-A.json
./glyph PingFangSC-Semibold 文 1000 > glyph-wen.json

# Icon Composer package (needs uv, Xcode, and
# https://github.com/giginet/apple-icon-composer-skill checked out). Overwrites any
# tweaks made in Icon Composer, so regenerate into a scratch path and compare first.
python3 build_icon.py <skill>/plugins/icon-composer/skills/compose-app-icon/scripts <out>/AppIcon.icon

# visionOS layers (needs rsvg-convert and Pillow)
python3 build_vision_icon.py ../../Translate/Assets.xcassets/VisionAppIcon.solidimagestack
```

Previews land in `preview/` (ignored by git).

## visionOS layer rules (Human Interface Guidelines)

- **Back**: the gradient, fully opaque, no alpha channel. The system masks it to a circle.
- **Middle**: the white "A" bubble with its border.
- **Front**: the dark "文" bubble, 88 % opaque so the white bubble shows through faintly, like the glass in the Icon Composer version.
- No shadows or highlights are baked in; visionOS adds depth, parallax, shadows and specular highlights from the layer order.
- The artwork is scaled so its farthest pixel sits 400 px from the center (the icon's radius is 512), leaving room for parallax inside the circular mask.
