import Foundation
import Testing
@testable import NookKit

@Suite("Article archive and metadata search") @MainActor
struct ArticleArchiveTests {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    var expiry: Date { start.addingTimeInterval(ArticleArchivePolicy.retention) }
    var article: Article { Fixture.article("a", feedID: "feed") }
    var feed: Feed { Fixture.feed("feed") }

    @Test func rolloffIsArchivedAndSearchable() {
        let store = ArticleArchiveStore(file: nil)
        store.sawFeed(feed, articles: [article], at: start)
        store.sawFeed(feed, articles: [], at: start.addingTimeInterval(1))
        #expect(!store.isCurrent(article))
        #expect(store.search("a").count == 1)
    }
    @Test func metadataSearchIncludesSummaryAndSourceNotBody() {
        let store = ArticleArchiveStore(file: nil)
        var a = article; a.summary = "Rare woodland discovery"; a.bodyParagraphs = ["privatebodyword"]
        store.sawFeed(feed, articles: [a], at: start)
        #expect(store.search("WOODLAND feed").count == 1)
        #expect(store.search("privatebodyword").isEmpty)
    }
    @Test func canonicalIdentityMergesFeedsAndHistory() {
        let store = ArticleArchiveStore(file: nil)
        var alias = article; alias.id = "alias"; alias.feedID = "other"
        alias.url = URL(string: article.url.absoluteString + "#part")!
        store.sawFeed(feed, articles: [article], at: start)
        store.sawFeed(Fixture.feed("other"), articles: [alias], at: start)
        let history = ReadingHistoryEntry(id: StableArticleIdentity.key(article), articleID: article.id,
            canonicalURL: article.url, title: article.title, feedID: feed.id, source: feed.title,
            publishedAt: article.publishedAt, firstOpenedAt: start, lastOpenedAt: start, snapshot: ArticleContent(article))
        #expect(store.search("", history: [history]).count == 1)
        #expect(store.search("").first?.contentCacheReference == article.id)
    }
    @Test func sameTitleDifferentURLIsNotMerged() {
        let store = ArticleArchiveStore(file: nil)
        var b = Fixture.article("b", feedID: feed.id); b.title = article.title
        store.sawFeed(feed, articles: [article, b], at: start)
        #expect(store.search("").count == 2)
    }
    @Test func ninetyDayBoundaryAndNoResurrectionOnReload() {
        let store = ArticleArchiveStore(file: nil)
        store.sawFeed(feed, articles: [article], at: start)
        store.sawFeed(feed, articles: [], at: start)
        store.prune(at: expiry.addingTimeInterval(-1)); #expect(store.entries.count == 1)
        store.prune(at: expiry); #expect(store.entries.isEmpty)
        store.synchronize([article], feeds: [feed], at: expiry)
        #expect(store.entries.isEmpty)
        store.sawFeed(feed, articles: [article], at: expiry)
        #expect(store.entries.count == 1)
    }
    @Test func savedAndCurrentSurviveRetention() {
        let store = ArticleArchiveStore(file: nil)
        var saved = article; saved.isStarred = true
        store.sawFeed(feed, articles: [saved], at: start)
        store.sawFeed(feed, articles: [], at: start)
        store.prune(at: expiry); #expect(store.entries.count == 1)
        store.sawFeed(feed, articles: [article], at: start)
        store.prune(at: expiry); #expect(store.entries.count == 1)
    }
    @Test func historyAndVocabularyReferencesSurviveRetention() {
        let store = ArticleArchiveStore(file: nil)
        store.sawFeed(feed, articles: [article], at: start)
        store.sawFeed(feed, articles: [], at: start)
        store.prune(at: expiry, protectedURLs: [article.url])
        #expect(store.entries.count == 1)
    }
    @Test func firstAndLastSeenDoNotResetAtLaunch() {
        let store = ArticleArchiveStore(file: nil)
        store.sawFeed(feed, articles: [article], at: start)
        store.synchronize([article], feeds: [feed], at: expiry)
        #expect(store.search("").first?.firstSeenAt == start)
        #expect(store.search("").first?.lastSeenAt == start)
    }
    @Test func filtersRespectReadSavedSourceAndDate() {
        let store = ArticleArchiveStore(file: nil)
        store.sawFeed(feed, articles: [article], at: start)
        var filter = ArchiveSearchFilter(); filter.state = .read
        #expect(store.search("", filter: filter).isEmpty)
        var a = article; a.isRead = true; a.isStarred = true; store.updateState(a)
        #expect(store.search("", filter: filter).count == 1)
        filter.state = .saved; filter.source = "missing"
        #expect(store.search("", filter: filter).isEmpty)
        filter.source = nil; filter.publishedAfter = expiry
        #expect(store.search("", filter: filter).isEmpty)
    }
    @Test func metadataAndMembershipReload() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("archive-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = ArticleArchiveStore(file: file)
        var a = article; a.heroImageURL = URL(string: "https://example.com/image.jpg"); a.newsCategory = .science
        store.sawFeed(feed, articles: [a], at: start)
        store.sawFeed(feed, articles: [], at: start)
        let reload = ArticleArchiveStore(file: file)
        #expect(reload.entries == store.entries)
        #expect(!reload.isCurrent(a))
        #expect(reload.search("").first?.content.heroImageURL == a.heroImageURL)
    }
    @Test func corruptionIsNotOverwritten() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("archive-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let bytes = Data("broken".utf8); try bytes.write(to: file)
        let store = ArticleArchiveStore(file: file)
        store.sawFeed(feed, articles: [article]); store.prune()
        #expect(try Data(contentsOf: file) == bytes)
    }
    @Test func nonFeedMetadataAndCacheReferenceArePreserved() {
        let store = ArticleArchiveStore(file: nil)
        var a = article; a.feedID = ReaderStore.savedLinksFeedID
        store.synchronize([a], feeds: [], at: start)
        #expect(store.search("").first?.sourceFeedID == nil)
        #expect(store.search("").first?.contentCacheReference == a.id)
    }
    @Test func savedAliasWinsAcrossFeedOrder() {
        let store = ArticleArchiveStore(file: nil)
        var saved = article; saved.id = "saved-copy"; saved.isStarred = true
        store.synchronize([saved, article], feeds: [feed], at: start)
        #expect(store.search("").count == 1)
        #expect(store.search("").first?.isSaved == true)
        store.synchronize([article, saved], feeds: [feed], at: start)
        #expect(store.search("").first?.isSaved == true)
    }
    @Test func removedFeedNoLongerPinsArchiveForever() {
        let store = ArticleArchiveStore(file: nil)
        store.sawFeed(feed, articles: [article], at: start)
        store.synchronize([], feeds: [], at: expiry)
        #expect(!store.isCurrent(article))
        store.prune(at: expiry)
        #expect(store.entries.isEmpty)
    }
    @Test func readAndSaveActionsApplyToCanonicalAliases() {
        let store = ReaderStore._makeForTesting()
        var alias = article; alias.id = "other-feed"; alias.isRead = true; alias.isStarred = true
        store.articles = [article, alias]; store.feeds = [feed]
        store.maintainArchive()
        store.setRead(articleID: article.id, isRead: false)
        store.setStarred(articleID: article.id, isStarred: false)
        #expect(store.libraryArticles.allSatisfy { !$0.isRead && !$0.isStarred })
        #expect(store.articleArchive.search("").first?.isSaved == false)
    }
    @Test func resettingLocalDataDoesNotResurrectInMemoryArchive() {
        let store = ArticleArchiveStore(file: nil)
        store.sawFeed(feed, articles: [article], at: start)
        store.didResetLocalData()
        #expect(store.search("").isEmpty)
        #expect(store.currentByFeed.isEmpty)
    }

}
