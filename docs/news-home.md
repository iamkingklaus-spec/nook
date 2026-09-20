# News Home (phase 2)

The iOS front page uses existing local articles, feed metadata, reader navigation,
and ReaderStore refresh. No new article-page requests, translation, image disk
cache, dependencies, Plus changes, or signing changes are involved.

## Structure

`HomeTab → NavigationStack → NewsHomeView → ScrollView / LazyVStack`

- Greeting and date, followed by a horizontally scrolling news section bar.
- One `HeroStoryCard` (16:9 image or typography), four `HorizontalStoryCard`s,
  then compact stories interleaved with horizontal stories every third item.
- 100 stories per layout page, with More stories retaining the edition inputs.
- iPad reuses NewsHomeView in the All Articles middle column; other sidebar
  scopes retain ArticleList, and the existing detail column retains Reader.

## Classification and identity

`NewsClassificationService` is deterministic and does not mutate Article.
An existing category with provenance is authoritative. Otherwise priority is:
Feed.newsCategoryOverride → RSS tags → article URL path → feed title / feed URL
host and path → title and summary keywords → Other display fallback.

Rule version is `news-home-1`. Matching uses complete normalized words/phrases;
ambiguous matches use a fixed order: Long Reads, Technology, Science, Business,
Culture, World. This conservative English/limited Chinese vocabulary is not a
semantic classifier. Feed folders and article user category IDs are never inputs.
Home-derived classifications remain projection values, so a rule update does not
mass-rewrite existing article records. Existing article provenance remains intact.

An explicit feed override is available from a story's context menu. It is an
optional field on Feed and an optional nullable LWW register on FeedState.
Clearing it writes a clocked nil, so a stale peer cannot resurrect it. The existing
state shard handles save, reload, merge, alias materialization, and legacy seeding;
the shared content replica continues to exclude this user setting. Missing fields
decode as nil. No destructive migration or schema bump is needed.

BBC's .com and .co.uk hosts share one identity; Guardian domains share another.
Other publishers use the normalized full site host, with a feed/URL fallback.
This avoids merging unrelated co.uk domains or unrelated tenants. It intentionally
does not implement a universal corporate publisher registry.

## For You ordering

For You is an aggregate edition, not a NewsCategory or personalized recommendation.
Pure projection inputs are articles, feeds, section, read-state snapshot, date,
and page limit. Outputs are hero, primary stories, secondary stories, and count.

1. Prefer the last 24 hours, then six-hour age bands; inside a band prefer unread,
   then descending date, then stable article ID.
2. Choose an image-bearing hero among the first six candidates only when it shares
   the first candidate's age band, 24-hour tier, and read state. Otherwise use text.
3. For You rotates the next twelve candidates within the same 24-hour tier using
   their original position plus penalties for repeating publisher (12) and section
   (3). Category pages keep the base order after hero selection. No importance score.
4. Older stories fill gaps. Layout work is bounded by page size plus lookahead.

The UI captures each article's read state for the current edition. Opening/reading
does not change that snapshot; pull-to-refresh starts another edition. Rendering
uses live read/star state and article IDs for actions. Projection runs in a detached
task and discards cancelled results. It is paused while the phone reader is pushed.

## Loading and navigation

Local content stays visible during refresh. First loading without articles has
static skeletons. No feeds and an empty news section have distinct messages.
Batch refresh exposes success/failure counts without a blocking alert, and changes
the successful refresh timestamp only when at least one feed succeeds.

Image URLs come exclusively from heroImageURL or rssImages (HTTP/S only). SwiftUI
AsyncImage provides loading; failed URLs are suppressed for the view's lifetime,
and the layout collapses to text. There is no manual retry or new disk cache.

Phone cards push the existing ReaderDetailView with the same selectedArticleID and
article-override binding used by other lists. iPad cards select the existing detail
and prefer it when the split view collapses. Section, edition, and ScrollView state
live in the Home view rather than the reader destination.

## Validation and limits

NewsHomeTests covers classification priority and provenance, identity aliases,
deterministic ordering, freshness/unread bounds, publisher rotation, category/Other
filtering, hero fallback, image candidates, identity after reading, pagination,
refresh timestamp rules, legacy decoding, LWW clearing, SQLite/state-shard reload,
and preservation across feed merge. Existing macOS CI runs unsigned iOS Debug and
Release builds plus all NookKit tests. Windows is not an Xcode build environment.

UI has semantic/scaled fonts, unrestricted title height, dark-mode theme colors,
VoiceOver card labels/actions, and Reduce Motion-aware scroll-to-top. Accessibility
text sizes drop horizontal thumbnails to preserve reading width. Skeletons do not
animate. Visual acceptance still needs Simulator/device checks: small iPhone,
iPad split/collapse, dark mode, largest Dynamic Type, VoiceOver, Reader push/pop,
read/star actions, pull-to-refresh, image failure, and partial/offline feeds.

Scroll position is retained by the mounted ScrollView on normal Reader return,
not persisted across process termination or rebuilding the iPad scope. Refreshes
and late-arriving images can change geometry. Full per-section offset restoration
and a universal publisher registry are later refinements. Tabs retain their current
Feeds/Starred names; renaming was optional. No phase 3 implementation is included.
