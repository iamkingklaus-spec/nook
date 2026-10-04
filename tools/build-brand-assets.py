"""Package approved imagegen masters for Apple platforms; no creative image edits.

Pillow performs only required size/mode conversions. Generated masters are kept
under design/, and the Icon Composer name/project references remain unchanged.
"""
from pathlib import Path
import json
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]


def generate():
    with Image.open(ROOT / "design/NookIconMaster.png") as source:
        icon = source.convert("RGB").resize((1024, 1024), Image.Resampling.LANCZOS)
    icon.save(ROOT / "design/Nook-AppIcon-1024.png")
    icon.save(ROOT / "Nook/AppIcon.icon/Assets/EditorialReader.png")
    for extension in ("NookShare", "NookShareSave", "NookShareDiscover"):
        icon.save(ROOT / extension / "Assets.xcassets/AppIcon.appiconset/AppIcon.png")
    with Image.open(ROOT / "design/NookLaunchMark.png") as source:
        mark = source.convert("RGBA")
        assert mark.getchannel("A").getextrema()[0] == 0, "Launch mark must have transparent background"
        for scale in (2, 3):
            mark.resize((104 * scale, 104 * scale), Image.Resampling.LANCZOS).save(
                ROOT / f"NookiOS/Assets.xcassets/LaunchLogo.imageset/LaunchLogo@{scale}x.png")
    manifest = {
        "fill": {"solid": "srgb:0.12,0.32,0.68,1.0"},
        "groups": [{"layers": [{"image-name": "EditorialReader.png", "name": "Editorial Reader", "glass": False}],
                    "shadow": {"kind": "neutral", "opacity": 0},
                    "translucency": {"enabled": False, "value": 0}}],
        "supported-platforms": {"circles": ["watchOS"], "squares": "shared"}
    }
    (ROOT / "Nook/AppIcon.icon/icon.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    generate()
