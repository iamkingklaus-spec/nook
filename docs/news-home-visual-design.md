# News Home visual design — phase 2.6

This is a presentation-only update. Classification, projection ranking, article
models, RSS parsing, image extraction, Reader, translation, Plus, and the existing
signing configurations are unchanged.

## Semantic palette

`NookiOS/NewsDesign.swift` is the source of truth. Dynamic UIKit colors resolve
against the current appearance. Home and the bottom navigation use these tokens;
Reader and Plus keep their own existing themes.

| Token | Light | Dark |
| --- | --- | --- |
| backgroundPrimary | #F8F6F0 | #12171D |
| backgroundSecondary | #F1EEE7 | #1A2027 |
| textPrimary | #101820 | #F2F0EA |
| textSecondary | #66707A | #AAB0B7 |
| textTertiary | #8A9097 | #808892 |
| accentPrimary | #203A5F | #6689B7 |
| accentSecondary | #9E3B32 | #C86A62 |
| divider | #E1DED5 | #303943 |
| borderSubtle | #DDD9D0 | #29323B |
| tabInactive | #737A82 | #808892 |

Navy is used for selected sections, underlines, actions and selected tabs. Muted red
is reserved for the existing refresh-failure message; there is no new breaking-news
state or category color scheme. Secondary surface/border tokens are defined for
consistency, not used to add card boxes.

## Typography and spacing

`NewsTypography` supplies sizes, weight, design, and the relative Dynamic Type
style. `NewsTypeStyle` scales via `@ScaledMetric`; titles have unrestricted height.

| Role | Base pt | Design / weight |
| --- | --- | --- |
| Greeting | 16 | System regular |
| Date | 34 | Serif semibold |
| Hero title | 28 | Serif bold |
| Horizontal title | 21 | Serif semibold |
| Compact title | 19 | Serif semibold |
| Hero summary | 17 | System regular |
| Other summary | 15.5 | System regular |
| Category | 16.5 | System regular / selected semibold |
| Metadata | 13 | System regular |
| Tab label / symbol | 11 / 21 | System semibold / regular |

Header gaps and top inset are reduced; the page keeps one 22pt horizontal grid.
Hero images remain 16:9, with 13pt corners and 17pt vertical content spacing.
Horizontal images use 4:3 and 9pt corners. Summary line spacing is 3pt and capped
at three hero lines / two horizontal lines. Titles add only 1pt line spacing.
Rules are 0.5pt, with no shadows or card backgrounds. iPad's news column requests
320–560pt (400pt ideal) while preserving the existing three-column hierarchy.

The category rail retains horizontal scrolling, adds 24pt trailing room and an
18pt alpha fade rather than a hard cut at the edge. Selection scrolls into view.
Its underline is 32×2pt, and buttons retain at least a 44pt touch height.
Once horizontally scrolled, the leading edge also fades instead of cutting a
partial label sharply. A 1pt top safe-area inset extends an opaque background
behind the status bar so scrolled headlines cannot overlap the clock or icons.

Metadata displays **publication age**, not an inferred read-time estimate:
Just now / integer min / integer hr / integer days. Publisher is slightly darker.
There are no seconds, including the card accessibility label. The article's
estimatedReadMinutes is not relabeled or changed.

## Bottom navigation

Home / Explore / Saved / Settings use icons and labels with the semantic colors.
The original destinations, selection state, repeat-tap behavior and existing
signed-in compose action are retained. There is no floating capsule, glass layer,
shadow, selection pill or scroll-down scaling.

The host provides the bar through an environment value. Each navigation root's
existing `TabBarInset` inserts the **actual bar** using `safeAreaInset`, so its
measured height reserves scrollable space. Normal height is at least 52pt; larger
text can grow naturally. Only the opaque background extends behind the home
indicator. Reader and Settings detail pushes retain their existing hide behavior.

## Reproducible visual review

The manual `iOS Simulator screenshots` workflow builds the unchanged production
app plus a small Apple XCTest UI target (no snapshot library). Disposable data is
imported from public RSS; the typography-only case removes image metadata from
that temporary library. No test-mode layout is compiled into the app.

The UI test captures For You, scrolled horizontal/compact stories, World,
Technology, typography hero, dark mode, the bottom of the list, and iPad. It also
asserts that the final article can scroll completely above the tab bar and that
all four destinations remain reachable, including an empty subscription library.
SwiftUI exposes the context-menu story wrappers as accessibility `Other` elements;
the UI queries follow that hierarchy. Devices match phase 2: iPhone 17 Pro
(1206×2622) and iPad Pro 13-inch M5 (2064×2752). Images and XCTest results are kept
as CI artifacts and must be visually inspected before acceptance. Screenshots and
text logs have a small review artifact; full XCTest bundles/recordings are retained
in a separate diagnostics artifact.

The existing baseline CI still owns unsigned Debug/Release builds and all
NookKit tests. Image sharpness is still limited by RSS-provided sources; this
phase does not implement higher-resolution extraction or an image pipeline.
