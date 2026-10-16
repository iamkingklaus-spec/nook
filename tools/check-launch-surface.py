"""Offline launch-resource regression check; does not replace an Xcode build."""
from pathlib import Path
import json
import plistlib
import re
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]


def check():
    info = plistlib.loads((ROOT / "NookiOS/Info.plist").read_bytes())
    name = info["UILaunchStoryboardName"]
    assert name == "NookieLaunch", "Info.plist still selects the old launch resource"
    path = ROOT / "NookiOS" / (name + ".storyboard")
    storyboard = ET.parse(path)
    assert storyboard.getroot().get("launchScreen") == "YES"
    assert not storyboard.findall(".//imageView") and not storyboard.findall(".//label"), "Launch must not display brand artwork or a wordmark"
    assert storyboard.find('.//color[@key="backgroundColor"]').get("name") == "LaunchBackground"

    project = (ROOT / "Nook.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
    assert f"path = {name}.storyboard;" in project
    assert f"{name}.storyboard in Resources" in project
    assert "LaunchScreen.storyboard" not in project
    assert not (ROOT / "NookiOS/LaunchScreen.storyboard").exists()
    assert not list((ROOT / "NookiOS/Assets.xcassets/LaunchLogo.imageset").glob("*"))
    exporter = (ROOT / "tools/build-brand-assets.py").read_text(encoding="utf-8")
    assert "LaunchLogo" not in exporter, "Asset export must not recreate retired startup artwork"

    root = (ROOT / "NookiOS/RootView.swift").read_text(encoding="utf-8")
    loading = root.split("struct StartupLoadingView: View {", 1)[1].split("/// A selectable sidebar entry", 1)[0]
    assert "StartupLoadingView(store: store)" in root and ".transition(.identity)" in root
    assert "SplashView" not in root and "LaunchLogo" not in root
    assert "Image(" not in loading and "BrandMark" not in loading
    assert ".animation(" not in loading and "Task.sleep" not in loading
    assert "NookTheme.backgroundPrimary" in loading and "phase.fractionComplete" in loading and "Text(phase.label)" in loading

    # System appearance must match the running app's default light/dark canvas.
    theme = (ROOT / "NookKit/Sources/NookKit/NookTheme.swift").read_text(encoding="utf-8")
    light, dark = re.search(r"backgroundPrimary = adaptive\(0x([A-Fa-f0-9]+), 0x([A-Fa-f0-9]+)\)", theme).groups()
    palette = json.loads((ROOT / "NookiOS/Assets.xcassets/LaunchBackground.colorset/Contents.json").read_text(encoding="utf-8"))
    for item in palette["colors"]:
        is_dark = any(a.get("value") == "dark" for a in item.get("appearances", []))
        expected = int(dark if is_dark else light, 16)
        components = item["color"]["components"]
        actual = tuple(round(float(components[c]) * 255) for c in ("red", "green", "blue"))
        assert actual == tuple((expected >> shift) & 255 for shift in (16, 8, 0))
    print("PASS: launch reference, background-only storyboard, retired assets, exporter, loading cover, light/dark palette")
    print("Static checks only; no Swift/Xcode build or device-cache verification.")


if __name__ == "__main__":
    check()
