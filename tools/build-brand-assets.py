"""Rebuild Nook's editable Icon Composer layers and raster exports (Pillow).

Original layered-page mark, based on the requested blue/white direction. No
reference image was attached. Geometry below is shared by SVG and raster output.
Run from any directory; does not change project, signing, or icon target names.
"""
from pathlib import Path
import json
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
ICON = ROOT / "Nook/AppIcon.icon"
SCALE = 3
LAYERS = [
    ("BackPage", "#A0C3FF", (236, 228, 748, 804), 62, -16),
    ("BluePage", "#3C78EA", (244, 216, 768, 800), 62, 9),
    ("FrontPage", "#FFFFFF", (260, 188, 764, 772), 58, 0),
]
INK = "#245BD7"
# An open, legible N with the geometry of folded reading sheets.
GLYPH = [(348, 582), (348, 314), (404, 314), (590, 503),
         (590, 314), (648, 314), (648, 582), (592, 582), (406, 393), (406, 582)]


def svg(body):
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">{body}</svg>\n'


def layer_entry(name, color):
    rgb = [int(color[i:i + 2], 16) / 255 for i in (1, 3, 5)]
    return {"image-name": name + ".svg", "name": name, "glass": False,
            "fill-specializations": [{"value": {"solid": "srgb:" + ",".join(f"{v:.5f}" for v in rgb) + ",1.00000"}},
                                     {"appearance": "tinted", "value": "automatic"}]}


def generate():
    assets = ICON / "Assets"
    assets.mkdir(parents=True, exist_ok=True)
    foreground = Image.new("RGBA", (1024 * SCALE, 1024 * SCALE))
    entries = []
    for name, color, box, radius, angle in LAYERS:
        x, y, right, bottom = box
        rect = f'<rect x="{x}" y="{y}" width="{right-x}" height="{bottom-y}" rx="{radius}" fill="{color}" transform="rotate({angle} 512 512)"/>'
        (assets / (name + ".svg")).write_text(svg(rect), encoding="utf-8")
        layer = Image.new("RGBA", foreground.size)
        ImageDraw.Draw(layer).rounded_rectangle(tuple(v * SCALE for v in box), radius * SCALE, fill=color)
        layer = layer.rotate(-angle, Image.Resampling.BICUBIC, center=(512 * SCALE, 512 * SCALE))
        foreground.alpha_composite(layer)
        entries.append(layer_entry(name, color))
    points = " ".join(f"{x},{y}" for x, y in GLYPH)
    ink_svg = f'<polygon points="{points}" fill="{INK}"/><rect x="348" y="642" width="300" height="20" rx="10" fill="{INK}"/>'
    (assets / "ReadingMark.svg").write_text(svg(ink_svg), encoding="utf-8")
    draw = ImageDraw.Draw(foreground)
    draw.polygon([(x * SCALE, y * SCALE) for x, y in GLYPH], fill=INK)
    draw.rounded_rectangle((348*SCALE, 642*SCALE, 648*SCALE, 662*SCALE), 10*SCALE, fill=INK)
    entries.append(layer_entry("ReadingMark", INK))
    manifest = {
        "fill": {"automatic-gradient": "srgb:0.90980,0.94902,1.00000,1.00000"},
        "groups": [{"layers": entries, "shadow": {"kind": "neutral", "opacity": 0.16},
                    "translucency": {"enabled": False, "value": 0}}],
        "supported-platforms": {"circles": ["watchOS"], "squares": "shared"}
    }
    (ICON / "icon.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    full = Image.new("RGB", foreground.size)
    gradient = ImageDraw.Draw(full)
    for y in range(full.height):
        fraction = y / (full.height - 1)
        color = tuple(round(a + (b-a)*fraction) for a, b in zip((239, 246, 255), (214, 231, 255)))
        gradient.line((0, y, full.width, y), fill=color)
    full.paste(foreground, mask=foreground.getchannel("A"))
    full = full.resize((1024, 1024), Image.Resampling.LANCZOS)
    export = ROOT / "design"
    export.mkdir(exist_ok=True)
    full.save(export / "Nook-AppIcon-1024.png")
    for extension in ["NookShare", "NookShareSave", "NookShareDiscover"]:
        full.save(ROOT / extension / "Assets.xcassets/AppIcon.appiconset/AppIcon.png")
    launch = ROOT / "NookiOS/Assets.xcassets/LaunchLogo.imageset"
    for scale in (2, 3):
        foreground.resize((104 * scale, 104 * scale), Image.Resampling.LANCZOS).save(launch / f"LaunchLogo@{scale}x.png")


if __name__ == "__main__":
    generate()
