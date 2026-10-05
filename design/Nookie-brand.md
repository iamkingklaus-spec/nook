# Nookie brand assets

The default icon was edited with the built-in imagegen tool using the supplied
white-haired, blue-eyed newspaper-reading character reference. No API key or
third-party art dependency is added to the app.

## Generation brief

Preserve the recognizable cheerful white-haired, blue-eyed character, blue bow
with newspaper ornament, white/cobalt clothing and newspaper. Preserve the
polished illustrative style and original charm. Produce square, full-bleed,
opaque artwork, with no rounded border, squircle, margin or inset mockup.
Blue fills the four corners. Face and eyes dominate; a clearly readable newspaper
sits at the lower right, within the central icon-safe region. Simplify wispy hair,
tiny newspaper lines and background; remove flying paper and small sparkles.
Use a luminous royal-blue/azure background with subtle clouds. No lettering,
watermarks or extra characters; cute, bright and clean, not neon.

## Assets

- `design/NookIconMaster.png`: generated master (legacy filename retained).
- `design/Nook-AppIcon-1024.png`: opaque 1024 px square export.
- `Nook/AppIcon.icon/Assets/EditorialReader.png`: shared iOS/macOS default layer.
- Three Share extensions retain their existing AppIcon asset paths.
- `NookiOS/Assets.xcassets/LaunchLogo.imageset`: 104 pt static launch artwork.
- `NookKit/Sources/NookKit/BrandAssets.xcassets`: package-owned character for
  the About, welcome and Vocabulary empty surfaces.

`tools/build-brand-assets.py` only packages/resizes the approved generated art.
The App Icon has no baked corner mask or transparent border. The operating
system supplies its shape; in-app brand tiles use the existing card radius.

The UI accent is #315FA0 (light) / #A4C5F1 (dark). Reading surfaces and typography
remain editorial. Launch is static and introduces no delay. Brand tiles fade
once in 180 ms; button feedback takes 120 ms. Reduce Motion disables these
transitions; existing Reduce Transparency handling remains in the shared theme.

Only display names change. Module/target names, bundle identifiers, URL schemes,
Keychain identities, local storage paths, Plus endpoints and IPA naming remain
compatible with existing installations.
