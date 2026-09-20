import Foundation
import Testing
@testable import NookKit

private let edition = Date(timeIntervalSince1970: 1_800_000_000)

private func story(_ id: String, feed: String = "f", hoursAgo: Double = 1,
                   category: NewsCategory? = nil, image: Bool = false, read: Bool = false) -> Article {
    var article = Fixture.article(id, feedID: feed, isRead: read)
    article.publishedAt = edition.addingTimeInterval(-hoursAgo * 3600)
    article.newsCategory = category
    article.newsCategoryProvenance = category == nil ? nil : .init(source: .manual)
    if image { article.heroImageURL = URL(string: "https://images.example.com/\(id).jpg") }
    return article
}

@Suite("News classification")
struct NewsClassificationTests {
    let service = NewsClassificationService()

    @Test(arguments: [("World", NewsCategory.world), ("finance", .business), ("Tech", .technology),
                      ("science", .science), ("arts", .culture), ("long-read", .longReads), ("科技", .technology)])
    func rssTags(_ tag: String, _ expected: NewsCategory) {
        var article = story("a"); article.rssTags = [tag]
        let result = service.classify(article, feed: nil)
        #expect(result.category == expected)
        #expect(result.provenance?.source == .rssTag)
        #expect(result.provenance?.ruleVersion == NewsClassificationService.ruleVersion)
    }

    @Test func urlPath() {
        var article = story("a")
        article.url = URL(string: "https://example.com/science/2026/new-discovery")!
        #expect(service.classify(article, feed: nil).category == .science)
        #expect(service.classify(article, feed: nil).evidence == .articlePath)
    }

    @Test func priority() {
        var feed = Fixture.feed("f"); feed.newsCategoryOverride = .world; feed.title = "Business"
        var article = story("a"); article.rssTags = ["Technology"]
        article.url = URL(string: "https://example.com/science/a")!
        #expect(service.classify(article, feed: feed).category == .world)
        feed.newsCategoryOverride = nil
        #expect(service.classify(article, feed: feed).category == .technology)
        article.rssTags = []
        #expect(service.classify(article, feed: feed).category == .science)
    }

    @Test func feedThenKeywords() {
        var feed = Fixture.feed("f"); feed.title = "Business bulletin"
        var article = story("a"); article.title = "New astronomy discovery"
        #expect(service.classify(article, feed: feed).category == .business)
        #expect(service.classify(article, feed: nil).category == .science)
    }

    @Test func unknownDoesNotMutate() {
        var article = story("a"); article.categories = ["my-folder-id"]
        let feed = Fixture.feed("f", category: "Technology")
        let result = service.classify(article, feed: feed)
        #expect(result.category == .other)
        #expect(result.provenance == nil)
        #expect(article.newsCategory == nil)
        #expect(article.categories == ["my-folder-id"])
        #expect(feed.category == "Technology")
    }

    @Test(arguments: [NewsCategoryProvenance.Source.manual, .feed, .rssTag, .rule])
    func preservesProvenance(_ source: NewsCategoryProvenance.Source) {
        var article = story("a", category: .culture)
        article.newsCategoryProvenance = .init(source: source, ruleVersion: "existing-v1")
        article.rssTags = ["Tech"]
        var feed = Fixture.feed("f"); feed.newsCategoryOverride = .science
        let result = service.classify(article, feed: feed)
        #expect(result.category == .culture)
        #expect(result.provenance == article.newsCategoryProvenance)
        #expect(result.evidence == .existing)
    }

    @Test func tagsAreOrderIndependent() {
        var a = story("a"); a.rssTags = ["World", "Science"]
        var b = a; b.rssTags.reverse()
        #expect(service.classify(a, feed: nil) == service.classify(b, feed: nil))
    }

    @Test func tokenBoundaries() {
        var article = story("a"); article.title = "Earth's birthday"
        #expect(service.classify(article, feed: nil).category == .other)
    }

    @Test func publisherAliases() {
        var a = Fixture.feed("world"); a.siteURL = URL(string: "https://www.bbc.co.uk/news")!
        var b = Fixture.feed("business"); b.siteURL = URL(string: "https://bbc.com/business")!
        #expect(NewsPublisher(feed: a, articleURL: a.siteURL) == NewsPublisher(feed: b, articleURL: b.siteURL))
        #expect(NewsPublisher(feed: a, articleURL: a.siteURL).name == "BBC")
        a.siteURL = URL(string: "https://www.theguardian.com/world")!
        b.siteURL = URL(string: "https://theguardian.com/technology")!
        #expect(NewsPublisher(feed: a, articleURL: a.siteURL) == NewsPublisher(feed: b, articleURL: b.siteURL))
    }

    @Test func publisherDoesNotSpoofOrMergePublicSuffixes() {
        let a = NewsPublisher(feed: nil, articleURL: URL(string: "https://fakebbc.com/a")!)
        let b = NewsPublisher(feed: nil, articleURL: URL(string: "https://one.co.uk/a")!)
        let c = NewsPublisher(feed: nil, articleURL: URL(string: "https://two.co.uk/a")!)
        #expect(a.id != "bbc")
        #expect(b.id != c.id)
    }
}

@Suite("News home projection")
struct NewsHomeProjectionTests {
    @Test func recentBeforeOldUnreadImage() {
        let result = NewsHomeProjection(articles: [story("old", hoursAgo: 25, image: true),
            story("new", hoursAgo: 1, read: true)], feeds: [], now: edition)
        #expect(result.hero?.id == "new")
        #expect(result.stories.map(\.id) == ["new", "old"])
    }

    @Test func unreadBiasIsBounded() {
        let result = NewsHomeProjection(articles: [story("unread", hoursAgo: 7),
            story("fresh", hoursAgo: 1, read: true)], feeds: [], now: edition)
        #expect(result.hero?.id == "fresh")
    }

    @Test func unreadWithinBand() {
        let result = NewsHomeProjection(articles: [story("read", hoursAgo: 1, read: true),
            story("unread", hoursAgo: 2)], feeds: [], now: edition)
        #expect(result.hero?.id == "unread")
    }

    @Test func heroImageAndTypographyFallback() {
        let text = story("text"); let image = story("image", hoursAgo: 2, image: true)
        #expect(NewsHomeProjection(articles: [text, image], feeds: [], now: edition).hero?.id == "image")
        let fallback = NewsHomeProjection(articles: [text], feeds: [], now: edition)
        #expect(fallback.hero?.id == text.id)
        #expect(fallback.hero?.imageURL == nil)
    }

    @Test func imageCandidatesAndInvalidScheme() {
        var article = story("a"); article.heroImageURL = URL(string: "file:///private/image.jpg")
        article.rssImages = [.init(url: URL(string: "https://example.com/thumb.jpg")!, provenance: .mediaThumbnail)]
        #expect(NewsHomeStory(article: article, feed: nil).imageURL == article.rssImages.first?.url)
        article.rssImages = []
        #expect(NewsHomeStory(article: article, feed: nil).imageURL == nil)
    }

    @Test func categoryFilteringAndOther() {
        let articles = [story("science", category: .science), story("business", category: .business), story("unknown")]
        let result = NewsHomeProjection(articles: articles, feeds: [], section: .category(.science), now: edition)
        #expect(result.stories.map(\.id) == ["science"])
        #expect(NewsHomeProjection(articles: articles, feeds: [], section: .category(.other), now: edition).hero?.id == "unknown")
        #expect(NewsHomeProjection(articles: articles, feeds: [], section: .category(.culture), now: edition).hero == nil)
    }

    @Test func publisherAndCategoryRotation() {
        var a = Fixture.feed("a"); a.siteURL = URL(string: "https://bbc.com")!
        var b = Fixture.feed("b"); b.siteURL = URL(string: "https://bbc.co.uk")!
        var c = Fixture.feed("c"); c.siteURL = URL(string: "https://theguardian.com")!
        let result = NewsHomeProjection(articles: [story("1", feed: "a", category: .world),
            story("2", feed: "b", category: .world), story("3", feed: "c", category: .science)],
            feeds: [a, b, c], now: edition)
        #expect(result.stories.map(\.id) == ["1", "3", "2"])
    }

    @Test func stableOrderingRegardlessOfInputOrder() {
        let articles = (0..<30).map { story(String(format: "%02d", $0), hoursAgo: Double($0 % 9)) }
        let first = NewsHomeProjection(articles: articles, feeds: [], now: edition).stories.map(\.id)
        let second = NewsHomeProjection(articles: articles.reversed(), feeds: [], now: edition).stories.map(\.id)
        #expect(first == second)
        #expect(Set(first).count == articles.count)
    }

    @Test func readingDoesNotChangeIdentityOrEditionOrder() {
        var articles = [story("1"), story("2"), story("3")]
        let snapshot = Dictionary(uniqueKeysWithValues: articles.map { ($0.id, $0.isRead) })
        let first = NewsHomeProjection(articles: articles, feeds: [], readState: snapshot, now: edition)
        articles[0].isRead = true
        let second = NewsHomeProjection(articles: articles, feeds: [], readState: snapshot, now: edition)
        #expect(first.stories.map(\.id) == second.stories.map(\.id))
        #expect(second.hero?.article.isRead == true)
        #expect(articles[0].id == "1")
    }

    @Test func boundedLayoutAndOlderFallback() {
        let articles = (0..<200).map { story(String(format: "%03d", $0), hoursAgo: 48) }
        let result = NewsHomeProjection(articles: articles, feeds: [], now: edition, limit: 20)
        #expect(result.totalCount == 200)
        #expect(result.stories.count == 20)
        #expect(result.primaryStories.count == 4)
        #expect(result.secondaryStories.count == 15)
        #expect(result.hero != nil)
    }

    @Test func emptyInput() {
        let result = NewsHomeProjection(articles: [], feeds: [], now: edition)
        #expect(result.hero == nil)
        #expect(result.totalCount == 0)
        #expect(result.stories.isEmpty)
    }

    @Test func refreshSuccessTimestamp() {
        #expect(NewsRefreshOutcome(succeeded: 0, failed: 3, completedAt: edition).successfulAt == nil)
        #expect(NewsRefreshOutcome(succeeded: 1, failed: 2, completedAt: edition).successfulAt == edition)
        #expect(NewsRefreshOutcome(succeeded: 0, failed: 0, completedAt: edition).successfulAt == nil)
    }
}

@Suite("Feed news override persistence")
struct FeedNewsOverrideTests {
    @Test func legacyFeedAndShardDecode() throws {
        let data = try JSONEncoder().encode(Fixture.feed("f"))
        #expect(try JSONDecoder().decode(Feed.self, from: data).newsCategoryOverride == nil)
        #expect(try JSONDecoder().decode(DeviceStateDocument.FeedState.self, from: Data("{}".utf8)).newsCategoryOverride == nil)
    }

    @Test func overrideRoundTripAndClearConverge() throws {
        let feed = Fixture.feed("f", category: "My folder")
        let library = Fixture.library(feeds: [feed], articles: [])
        var a = DeviceStateDocument(deviceID: "a")
        a.setFeedNewsCategory("f", .technology, hlc: Fixture.hlc(1))
        let loaded = try JSONDecoder().decode(DeviceStateDocument.self, from: JSONEncoder().encode(a))
        let enriched = DeviceStateDocument.materialize(base: library, shards: [loaded])
        #expect(enriched.feeds.first?.newsCategoryOverride == .technology)
        #expect(enriched.feeds.first?.category == "My folder")
        var b = DeviceStateDocument(deviceID: "b")
        b.setFeedNewsCategory("f", nil, hlc: Fixture.hlc(2))
        #expect(DeviceStateDocument.materialize(base: library, shards: [loaded, b]).feeds.first?.newsCategoryOverride == nil)
        #expect(DeviceStateDocument.materialize(base: library, shards: [b, loaded]).feeds.first?.newsCategoryOverride == nil)
    }

    @Test @MainActor func refreshPreservesOverride() {
        let store = ReaderStore._makeForTesting()
        var feed = Fixture.feed("f"); feed.newsCategoryOverride = .culture
        store.feeds = [feed]
        store._mergeForTesting(ParsedFeed(feed: Fixture.feed("f"), articles: [story("a")]))
        #expect(store.feeds.first?.newsCategoryOverride == .culture)
    }

    @Test func replicaAndStateShardReload() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "news-home-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = ReaderStorage(directoryURL: root.appending(path: "sync"))
        let db = root.appending(path: "db")
        let replica = try ReplicaStore(syncDirectory: storage.directoryURL, deviceID: "a", databaseDirectory: db)
        _ = try replica.recordLocal(Fixture.library(feeds: [Fixture.feed("f")], articles: []), retainBodies: [])
        try replica.publishIfNeeded(to: storage)
        var shard = DeviceStateDocument(deviceID: "a")
        shard.setFeedNewsCategory("f", .science, hlc: Fixture.hlc(42))
        try storage.saveShard(shard)
        let reopened = try ReplicaStore(syncDirectory: storage.directoryURL, deviceID: "a", databaseDirectory: db)
        let base = try reopened.reconcile(storage: storage).library
        let loaded = DeviceStateDocument.materialize(base: base, shards: try storage.loadShards())
        #expect(loaded.feeds.first?.newsCategoryOverride == .science)
        #expect(shard.maxObservedHLC == Fixture.hlc(42))
    }
}
