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
    # Export the same opaque, square character art. iOS applies the App Icon
    # mask; never bake a rounded rectangle or a transparent corner into it.
    for scale in (2, 3):
        icon.resize((104 * scale, 104 * scale), Image.Resampling.LANCZOS).save(
            ROOT / f"NookiOS/Assets.xcassets/LaunchLogo.imageset/LaunchLogo@{scale}x.png")
    brand = ROOT / "NookKit/Sources/NookKit/BrandAssets.xcassets"
    character = brand / "NookieCharacter.imageset"
    character.mkdir(parents=True, exist_ok=True)
    (brand / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n", encoding="utf-8")
    icon.resize((512, 512), Image.Resampling.LANCZOS).save(character / "NookieCharacter.png")
    (character / "Contents.json").write_text(json.dumps({"images": [{"filename": "NookieCharacter.png", "idiom": "universal"}], "info": {"author": "xcode", "version": 1}}, indent=2) + "\n", encoding="utf-8")
    manifest = {
        "fill": {"solid": "srgb:0.12,0.32,0.68,1.0"},
        "groups": [{"layers": [{"image-name": "EditorialReader.png", "name": "Nookie Reader", "glass": False}],
                    "shadow": {"kind": "neutral", "opacity": 0},
                    "translucency": {"enabled": False, "value": 0}}],
        "supported-platforms": {"circles": ["watchOS"], "squares": "shared"}
    }
    (ROOT / "Nook/AppIcon.icon/icon.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    generate()
