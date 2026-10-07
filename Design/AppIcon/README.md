# App icon source

`Translate/AppIcon.icon` is an Icon Composer 2 package (Xcode 27). Every layer is an SVG; open it in Icon Composer to tweak colors, glass, or layout.

To regenerate from parameters (bubble geometry, glyphs, gradient stops):

```bash
# 1. Glyph outlines (CoreText → SVG path data)
swiftc -O glyph.swift -o glyph
./glyph SFPro-Semibold A 1000 > glyph-A.json
./glyph PingFangSC-Semibold 文 1000 > glyph-wen.json

# 2. Build + validate + render previews (needs uv, Xcode, and
#    https://github.com/giginet/apple-icon-composer-skill checked out)
python3 build_icon.py <path-to-skill>/plugins/icon-composer/skills/compose-app-icon/scripts ../../Translate/AppIcon.icon
```

Layers (front → back): 文 glyph, rainbow border, dark glass bubble; A glyph, rainbow border, white glass bubble. Background is an indigo → violet gradient with a darker dark-mode variant; tinted and clear renditions are derived by the system.
