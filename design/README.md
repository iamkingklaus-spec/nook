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

## Polish 2.0

Light: #F7F8FA canvas, #FCFDFE surface, #202A38 text, #365A92 accent.
Dark: #171C24 canvas, #242D3A surface, #EEEDE8 text, #A0BAE3 accent.
Secondary translated text is #566273 / #B8C0CB, not a low-opacity overlay.
Radii: thumbnail 6, image/control 10, card 12, sheet 20 points. Reader tool targets
are 48 points. Display/title/headline are editorial serif; functional UI is sans.
Home retains its existing Dynamic Type sizes, hierarchy and layout.

Settings' Appearance picker stores `appAppearance` locally. The existing root
uses `preferredColorScheme`; changing it neither changes view identity nor clears
navigation state. System removes the override. No network or translation action
is coupled to this setting. The OS launch screen follows system appearance; the
stored override applies once the SwiftUI scene loads (an OS launch limitation).

Source audit: Home, Reader EN/Dual, Explore, Saved, History, Vocabulary, Settings,
Feeds, Feed Health, OPML preview, Search, sheets, empty/loading/error states were
reviewed. They inherit the shared theme; Article Info also now uses `nookScreen`.
Removed independent loading/pull/coach-mark materials and heavy shadows. Reader
motion respects Reduce Motion, and all shared glass respects Reduce Transparency.
Kept shadows behind video playback icons for contrast over arbitrary video imagery.
Related Coverage has no dedicated view in this checkout; no new feature was added.

## Default icon

`NookIconMaster.png` is the generated imagegen edit of the user's blue/white ribbon
reference. Prompt: preserve the blue gradient, frosted overlapping ribbons and
negative space; add only a minimal central reader head/shoulder silhouette; no
text, border, neon or extra detail. Built-in imagegen was used, not the API CLI.
`NookLaunchMark.png` was derived with imagegen's transparent-background extraction.
Generated masters are preserved; the old N-shaped SVG mark is retired.

Run `python tools/build-brand-assets.py` with Pillow to package the masters into
the opaque 1024px export, default Icon Composer PNG, three Share extension icons
and launch scales. This performs only size/mode conversion. No alternate icon.
The default icon name/project references are unchanged; macOS shares this asset.
iOS supplies the outer mask; app icon PNGs have no alpha or pre-rounded corners.

## Device review

Check light/dark mode, accessibility text sizes and Reduce Transparency in Reader,
Settings, Explore, Saved, History, Vocabulary, Feed Health and OPML preview. Check
Reader custom colors, toolbars and safe areas on iPhone and iPad. Confirm the icon
and LaunchScreen-to-bootstrap handoff after a fresh install. Windows resource and
diff checks do not replace an Xcode build or device visual review. Also verify
Appearance changes without leaving the current Settings route, system-mode changes,
long bilingual paragraphs/titles, Search keyboard, empty/error states and popovers.
No Simulator/device visual verification, CI or IPA build was performed on Windows.
