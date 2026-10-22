"""Offline metadata regressions; Apple binary inspection is mocked, not verified."""
import importlib.util
from pathlib import Path
import plistlib
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("package_ipa", ROOT / "tools/package-personal-ipa.py")
PACKAGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PACKAGE)


class ExtensionMetadataTests(unittest.TestCase):
    SOURCES = {
        "NookShareExtension.appex": "NookShare",
        "NookShareSaveExtension.appex": "NookShareSave",
        "NookShareDiscoverExtension.appex": "NookShareDiscover",
    }

    def verify(self, name, mutate=lambda info: None):
        # Use the checked-in extension declaration, then supply built-bundle keys.
        with (ROOT / self.SOURCES[name] / "Info.plist").open("rb") as source:
            info = plistlib.load(source)
        identifier = "com.example.nook.ios" + PACKAGE.EXTENSIONS[name]
        info.update(CFBundleIdentifier=identifier, CFBundleExecutable="Extension",
                    CFBundleSupportedPlatforms=["iPhoneOS"])
        mutate(info)
        with tempfile.TemporaryDirectory() as temporary:
            bundle = Path(temporary) / name
            bundle.mkdir()
            (bundle / "Info.plist").write_bytes(plistlib.dumps(info))
            (bundle / "Extension").write_bytes(b"fixture")
            with patch.object(PACKAGE.os, "access", return_value=True), \
                 patch.object(PACKAGE, "run", side_effect=["arm64", "platform IOS\n"]), \
                 patch.object(PACKAGE.subprocess, "run", return_value=SimpleNamespace(stdout=b"", stderr=b"")):
                return PACKAGE.verify_bundle(bundle, identifier)

    def test_share_declaration(self):
        self.assertEqual(self.verify("NookShareExtension.appex")["bundle"], "NookShareExtension.appex")

    def test_save_uses_share_services(self):
        self.assertEqual(self.verify("NookShareSaveExtension.appex")["bundle"], "NookShareSaveExtension.appex")

    def test_discover_remains_action_extension(self):
        self.assertEqual(self.verify("NookShareDiscoverExtension.appex")["bundle"], "NookShareDiscoverExtension.appex")

    def test_missing_declaration_rejected(self):
        for name in self.SOURCES:
            with self.subTest(name=name), self.assertRaisesRegex(RuntimeError, "extension.*declaration"):
                self.verify(name, lambda info: info.pop("NSExtension"))

    def test_wrong_extension_point_rejected(self):
        def change(info):
            extension = info["NSExtension"]
            extension["NSExtensionPointIdentifier"] = (
                "com.apple.ui-services" if extension["NSExtensionPointIdentifier"] == "com.apple.share-services"
                else "com.apple.share-services")
        for name in self.SOURCES:
            with self.subTest(name=name), self.assertRaisesRegex(RuntimeError, "extension.*declaration"):
                self.verify(name, change)

    def test_wrong_bundle_identifier_rejected(self):
        with self.assertRaisesRegex(RuntimeError, "Unexpected Bundle ID"):
            self.verify("NookShareSaveExtension.appex", lambda info: info.update(CFBundleIdentifier="wrong.id"))


if __name__ == "__main__":
    unittest.main()
