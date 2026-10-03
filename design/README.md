# Nook visual system

`NookKit/Sources/NookKit/NookTheme.swift` owns the adaptive palette, typography,
spacing, radii and shared screen, row, card, material and action styles. Home's
`NewsPalette` and package screens' `PlusTheme` are compatibility aliases, not
separate palettes. Home keeps its existing scalable editorial type sizes.

Use opaque surfaces for reading and grouped rows. Reserve `nookGlass` for compact
chrome; it switches to a solid surface when Reduce Transparency is enabled.
Reader font and custom-color preferences remain available.

The iOS AccentColor, ListBackground and LaunchBackground assets mirror the theme
for system and launch surfaces. Update both appearances when changing those tokens.

## Default icon

The original layered-page mark uses the requested blue/white direction; no user
reference image was attached to this design request. Editable SVG layers and the
existing Icon Composer manifest live in `Nook/AppIcon.icon`. The default icon name
and project references are unchanged. The app's macOS target shares this asset.

Run `python tools/build-brand-assets.py` with Pillow to regenerate the SVG layers,
manifest, opaque 1024px export, Share extension icons and launch images from the
same geometry. Pillow is a development-only asset export dependency.

`Nook-AppIcon-1024.png` is the standalone raster export. Icon Composer can vary its
platform lighting; the raster export uses a static cool gradient. iOS supplies
the app icon mask; the raster has no alpha or pre-rounded outer corners.

## Device review

Check light/dark mode, accessibility text sizes and Reduce Transparency in Reader,
Settings, Explore, Saved, History, Vocabulary, Feed Health and OPML preview. Check
Reader custom colors, toolbars and safe areas on iPhone and iPad. Confirm the icon
and LaunchScreen-to-bootstrap handoff after a fresh install. Windows resource and
diff checks do not replace an Xcode build or device visual review.
