#!/usr/bin/env python3
"""Package an unsigned device build and verify the extracted IPA, on macOS."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import zipfile


EXTENSIONS = {
    "NookShareExtension.appex": ".share",
    "NookShareSaveExtension.appex": ".share-save",
    "NookShareDiscoverExtension.appex": ".share-discover",
}


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def verify_personal_settings(settings_path, entitlements_path):
    with entitlements_path.open("rb") as source:
        entitlements = plistlib.load(source)
    require(entitlements == {}, "Personal entitlements must remain empty; no author-service capabilities")
    settings = json.loads(settings_path.read_text())
    targets = {entry["target"]: entry["buildSettings"] for entry in settings}
    require("NookiOS" in targets, "Missing NookiOS build settings")
    # -showBuildSettings may list only the scheme's explicit buildable. Embedded
    # extensions are verified from the actual extracted bundles below; all targets
    # receive the same command-line architecture and no-signing overrides.
    expected = {"NookiOS"} | {name.removesuffix(".appex") for name in EXTENSIONS}
    for target in expected.intersection(targets):
        build = targets[target]
        require(build.get("PLATFORM_NAME") == "iphoneos", f"Not an iPhoneOS build: {target}")
        require(build.get("ARCHS") == "arm64", f"Not arm64-only: {target}")
        require(build.get("CODE_SIGNING_ALLOWED") == "NO", f"Signing unexpectedly enabled: {target}")
        for key in ["DEVELOPMENT_TEAM", "CODE_SIGN_IDENTITY", "PROVISIONING_PROFILE_SPECIFIER", "PROVISIONING_PROFILE"]:
            require(not build.get(key), f"Unexpected signing setting {key}: {target}")
        configured = build.get("CODE_SIGN_ENTITLEMENTS", "")
        if target == "NookiOS" or configured:
            resolved = (Path(build["SRCROOT"]) / configured).resolve()
            require(resolved == entitlements_path.resolve(), f"Not using personal entitlements: {target}")


def verify_bundle(bundle, expected_id=None):
    with (bundle / "Info.plist").open("rb") as source:
        info = plistlib.load(source)
    require(info.get("CFBundleSupportedPlatforms") == ["iPhoneOS"], f"Not a device bundle: {bundle.name}")
    identifier = info["CFBundleIdentifier"]
    if expected_id:
        require(identifier == expected_id, f"Unexpected Bundle ID: {bundle.name}: {identifier}")
        point = "com.apple.share-services" if bundle.name == "NookShareExtension.appex" else "com.apple.ui-services"
        require(info.get("NSExtension", {}).get("NSExtensionPointIdentifier") == point,
                f"Missing share extension declaration: {bundle.name}")
    name = info["CFBundleExecutable"]
    require(Path(name).name == name, f"Invalid executable path: {bundle.name}")
    executable = bundle / name
    require(executable.is_file() and os.access(executable, os.X_OK), f"Executable missing or not executable: {bundle.name}")
    architectures = run("xcrun", "lipo", "-archs", str(executable)).split()
    require(architectures == ["arm64"], f"Unexpected Mach-O architecture: {bundle.name}: {architectures}")
    platform = run("xcrun", "vtool", "-show-build", str(executable))
    require(re.search(r"platform\s+IOS\s", platform + "\n") is not None,
            f"Mach-O is not built for iPhoneOS: {bundle.name}")
    # Ad-hoc linker signatures are harmless; no signing identity or profile is
    # supplied. Any unexpected signed capabilities must still fail validation.
    signed = subprocess.run(["codesign", "-d", "--entitlements", ":-", str(bundle)], capture_output=True)
    require(b"webcredentials:nooker.app" not in signed.stdout + signed.stderr,
            f"Author associated domain in signed entitlements: {bundle.name}")
    return {"bundle": bundle.name, "bundleID": identifier, "executable": name,
            "architectures": architectures, "platform": "iPhoneOS"}


def package(app, settings, entitlements, output):
    require(app.name == "NookiOS.app" and app.is_dir(), "Missing NookiOS.app device build")
    verify_personal_settings(settings, entitlements)
    output.mkdir(parents=True, exist_ok=True)
    ipa = output / "Nook-V1-Personal.ipa"
    require(not ipa.exists(), "Refusing to reuse an existing IPA output")
    with tempfile.TemporaryDirectory(prefix="nook-personal-") as temporary:
        root = Path(temporary)
        payload = root / "Payload"
        payload.mkdir()
        subprocess.run(["ditto", str(app), str(payload / "NookiOS.app")], check=True)
        subprocess.run(["ditto", "-c", "-k", "--norsrc", "--keepParent", str(payload), str(ipa)], check=True)
        with zipfile.ZipFile(ipa) as archive:
            require(archive.testzip() is None, "IPA ZIP integrity check failed")
            require(all(name.startswith("Payload/") and ".." not in Path(name).parts for name in archive.namelist()),
                    "Unexpected IPA root or path")
        extracted = root / "unpacked"
        subprocess.run(["ditto", "-x", "-k", str(ipa), str(extracted)], check=True)
        require({p.name for p in (extracted / "Payload").iterdir()} == {"NookiOS.app"}, "Unexpected Payload contents")
        unpacked_app = extracted / "Payload/NookiOS.app"
        main = verify_bundle(unpacked_app)
        extensions = unpacked_app / "PlugIns"
        require({p.name for p in extensions.glob("*.appex")} == set(EXTENSIONS), "Share extensions are incomplete")
        reports = [verify_bundle(extensions / name, main["bundleID"] + suffix) for name, suffix in EXTENSIONS.items()]
        for path in unpacked_app.rglob("*"):
            require(path.suffix.lower() not in {".mobileprovision", ".provisionprofile", ".p12", ".pfx", ".cer", ".pem", ".key"},
                    f"Unexpected signing material: {path.relative_to(unpacked_app)}")
            if path.suffix in {".entitlements", ".xcent"}:
                with path.open("rb") as source:
                    capabilities = plistlib.load(source)
                require("webcredentials:nooker.app" not in str(capabilities), "Author entitlement embedded as a resource")
        with ipa.open("rb") as source:
            hasher = hashlib.sha256()
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                hasher.update(chunk)
            digest = hasher.hexdigest()
        report = {"file": ipa.name, "sizeBytes": ipa.stat().st_size,
                  "sha256": digest,
                  "commit": os.environ.get("GITHUB_SHA"), "zipVerified": True,
                  "personalEntitlements": {}, "main": main, "extensions": reports}
    (output / "Nook-V1-Personal.validation.json").write_text(json.dumps(report, indent=2) + "\n")
    (output / "Nook-V1-Personal.ipa.sha256").write_text(f"{report['sha256']}  {ipa.name}\n")
    print(json.dumps(report, indent=2), flush=True)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as stream:
            stream.write(f"\n## Unsigned personal iPhoneOS IPA\n\nFile: `{ipa.name}`\n\n")
            stream.write(f"Size: {report['sizeBytes']} bytes\n\nSHA-256: `{report['sha256']}`\n\n")
            stream.write("Extracted ZIP verified; main app and all three Share extensions are iPhoneOS arm64.\n")
            stream.write("No signing identity or provisioning profile supplied. Re-signing and device installation are external to CI.\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--settings", type=Path, required=True)
    parser.add_argument("--entitlements", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    package(args.app, args.settings, args.entitlements, args.output)
