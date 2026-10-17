import Foundation
import Testing
@testable import NookKit

@Suite("Share URL handoff") @MainActor
struct SharedArticleHandoffTests {
    let url = URL(string: "https://example.com/article?edition=uk")!
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("inbox-\(UUID())") }

    @Test func validURLCanonicalizesWithoutGuessingContentURL() throws {
        #expect(try SharedArticleURL.validate(" HTTPS://EXAMPLE.COM:443/article?edition=uk#part ") == url)
        #expect(try SharedArticleURL.validate("https://example.com/Article") != SharedArticleURL.validate("https://example.com/article"))
    }
    @Test func malformedAndNonWebURLsFail() {
        for text in ["", "not a url", "example.com/article", "https://", "file:///etc/passwd", "javascript:alert(1)",
                     "data:text/html,hello", "ftp://example.com/news", "https://user:password@example.com/a"] {
            #expect(throws: (any Error).self) { try SharedArticleURL.validate(text) }
        }
    }
    @Test func sharedTextSupportsProvisionalTitlePlusURL() throws {
        #expect(try SharedArticleURL.fromSharedText("A newspaper story\nhttps://example.com/article?edition=uk") == url)
    }
    @Test func envelopeAndQueueSurviveProcessRestart() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let envelope = try SharedArticleEnvelope(url: url, title: "An article")
        try SharedArticleInbox(directory: dir).enqueue(envelope)
        #expect(try SharedArticleInbox(directory: dir).pending() == [envelope])
    }
    @Test func acknowledgementDoesNotLoseNewArrival() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let inbox = SharedArticleInbox(directory: dir)
        let first = try SharedArticleEnvelope(url: url), second = try SharedArticleEnvelope(url: url)
        try inbox.enqueue(first); _ = try inbox.pending(); try inbox.enqueue(second)
        try inbox.acknowledge(first)
        #expect(try inbox.pending() == [second])
    }
    @Test func noAppGroupCannotPretendToSave() throws {
        let inbox = SharedArticleInbox(directory: nil)
        #expect(throws: (any Error).self) { try inbox.enqueue(SharedArticleEnvelope(url: url)) }
        #expect(try inbox.pending().isEmpty)
    }
    @Test func malformedQueueItemDoesNotBlockValidItems() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let inbox = SharedArticleInbox(directory: dir), envelope = try SharedArticleEnvelope(url: url)
        try inbox.enqueue(envelope)
        try Data("broken".utf8).write(to: dir.appendingPathComponent("broken.json"))
        let scan = try inbox.scanPending()
        #expect(scan.items == [envelope]); #expect(scan.invalidCount == 1)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("broken.json").path))
    }
    @Test func failedImportIsRetainedForRetry() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let inbox = SharedArticleInbox(directory: dir), envelope = try SharedArticleEnvelope(url: url)
        try inbox.enqueue(envelope)
        let failed = try await SharedArticleImport.drain(inbox) { _ in throw CocoaError(.fileWriteOutOfSpace) }
        #expect(failed.failed == 1); #expect(try inbox.pending() == [envelope])
        let success = try await SharedArticleImport.drain(inbox) { _ in }
        #expect(success.imported == 1); #expect(try inbox.pending().isEmpty)
    }
    @Test func RSSDuplicateReusesArticleIdentityWithoutNetwork() async throws {
        let store = ReaderStore._makeForTesting()
        var article = Fixture.article("rss-id", feedID: "rss"); article.url = url
        store.articles = [article]
        #expect(try await store.saveLink(urlString: url.absoluteString + "#part") == article.id)
        #expect(store.libraryArticles.count == 1)
    }
    @Test func duplicateQueueSharesResolveToOneArticle() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let inbox = SharedArticleInbox(directory: dir)
        try inbox.enqueue(SharedArticleEnvelope(url: url)); try inbox.enqueue(SharedArticleEnvelope(url: url))
        let store = ReaderStore._makeForTesting()
        var article = Fixture.article("cache-id", feedID: ReaderStore.savedLinksFeedID); article.url = url
        store.articles = [article]
        var imported: Set<String> = []
        _ = try await SharedArticleImport.drain(inbox) { value in
            imported.insert(try await store.saveLink(urlString: value.url.absoluteString))
        }
        #expect(imported == [article.id]); #expect(store.libraryArticles.count == 1)
    }
    @Test func nonFeedArticleEntersArchiveAndHistoryWithSameCacheReference() throws {
        let file = directory().appendingPathComponent("history.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = ReaderStore._makeForTesting()
        let history = ReadingHistoryStore(file: file)
        var article = Fixture.article("shared-id", feedID: ReaderStore.savedLinksFeedID); article.url = url
        let restored = store.restoreArchivedArticle(article)
        store.maintainArchive(); history.recordOpened(restored, feed: nil)
        let entry = try #require(store.articleArchive.search("").first)
        #expect(entry.sourceFeedID == nil)
        #expect(entry.contentCacheReference == history.entries.first?.articleID)
        #expect(store.restoreArchivedArticle(article).id == restored.id)
        #expect(store.libraryArticles.count == 1)
    }
    @Test func invalidURLFailsBeforeStorageOrNetwork() async {
        let store = ReaderStore._makeForTesting()
        do {
            _ = try await store.saveLink(urlString: "javascript:alert(1)")
            Issue.record("Invalid URL was accepted")
        } catch {
            #expect(error is SharedArticleError)
            #expect(store.libraryArticles.isEmpty)
        }
    }
}
