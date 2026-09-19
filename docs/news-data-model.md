# News data model (phase 1)

This is an additive data/persistence change. It does not add a home screen,
reader/translation UI, classification engine, extraction request or Gemini call.

## Data boundaries

- `NewsCategory` has `world`, `business`, `technology`, `science`, `culture`,
  `longReads` and `other`. A missing category is `nil`, not a guessed `other`.
- `newsCategoryProvenance` pairs a source (`feed`, `rssTag`, `rule`, `manual`)
  with an optional rule version. Classification is intentionally not run yet.
- `Feed.category` remains the user's folder. `Article.categories` remains the
  user's category IDs, synchronized by the existing device-state registers.
- `feedItemGUID` preserves an opaque RSS GUID / Atom ID. Existing article IDs
  are unchanged; this is not an identity migration.
- `rssTags` preserves ordered, exact, nonempty RSS category text / Atom category
  terms, deduplicating identical values. They never populate user categories.
- `rssImages` retains image enclosure, Media RSS content and thumbnail candidates,
  with URLs, provenance and MIME type. The provisional hero uses the first image
  enclosure, then media content, then thumbnail. Relative image URLs honor the
  XML base; only HTTP(S) images are accepted. No image download is performed.
- `subtitle` is optional. Summary and subtitle retain distinct meanings.

## Content and document

`ArticleContentSource` distinguishes feed full-content fields, feed descriptions
and extracted reader content. `ArticleContentQuality` is a separate assessment:
`unknown`, `complete`, `partial`, `empty`, or `failed`. A full-content tag does not
prove completeness. Parsing only identifies empty vs unknown; later phases may
assess completeness without changing source provenance.

`ArticleSourceContent` keeps each raw payload separately with its format and
source element. RSS description and content:encoded (or Atom summary/content)
are both kept, including markup. Nested Atom XHTML is preserved. The extracted
reader source is available for later producers; no extraction flow is changed.

`ArticleDocument` is a schema-versioned, immutable input to future paragraph
translation. It contains source blocks, not translations. No automatic DOM
segmentation is added in this phase. A block's hash is SHA-256 over length-framed
UTF-8 version/kind/format/source content. Its ID adds an occurrence ordinal among
identical blocks. The document hash includes schema, source and ordered block IDs.

Identical input gives identical hashes across devices/processes. Inserting an
unrelated block preserves existing IDs; changing text/kind/format changes the
block ID; reordering changes the document hash. Duplicate equal blocks get unique
ordinals in source order. Inserting/removing another identical block can shift
those duplicate ordinals: content alone cannot distinguish such occurrences.
IDs are scoped to the article. Persisted hashes are recomputed during decoding
so stale cached hashes cannot override source content.

## Persistence and migration

`ArticleContent` carries all small news fields in the existing content LWW
register. Raw `sourceContents` and `document` travel with `ArticleBody` in the
body sidecar/shard. The complete round-trip is:

```swift
ArticleContent(article).makeArticle(body: article.body)
```

List-light baseline encoding strips both old and new heavy body fields. All
body hydration paths restore the full envelope together. Bodies keep the
existing bounded retention policy; after eviction, news metadata remains while
raw source/document data is absent and must be regenerated. Future translation
results that require permanent retention should not be placed in this cache.

SQLite already stores Codable content/body documents as BLOB payloads; no SQL
column/table migration, destructive rewrite, or changed database identity is
required. `Article` and `ArticleContent` explicitly decode missing optional
fields as nil and arrays as empty. `ArticleBody` also tolerates absent new fields.
The additive content/body shard envelopes remain schema 2; the new document
has its own schemaVersion 1. Old JSON libraries and shards continue to open.

Content merges retain the existing whole-article HLC last-writer-wins rule,
including news fields. User-state materialization changes only user state.
RSS refresh preserves existing news classification and independent extracted
content. An unchanged RSS source retains its document and quality; a changed
source invalidates the old RSS document. The body cache uses the merged result.
An older binary can ignore new JSON keys but cannot be expected to preserve
them when rewriting an article; this is backward reading compatibility, not a
guarantee for simultaneous edits from downgraded clients.

## Verification

The news model, persistence and parser test suites cover legacy decoding,
save/reopen, ArticleContent+body round-trip, state/category independence,
hero/GUID/tag metadata, body retention, peer merge, actual refresh merging,
and stable document/block identity. Existing tests remain unchanged.
The existing macOS CI remains responsible for actual Simulator Debug/Release
builds and the full NookKit test suite; Windows static checks are not builds.
