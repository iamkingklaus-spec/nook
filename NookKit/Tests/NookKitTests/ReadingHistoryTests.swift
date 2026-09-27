import Foundation
import Testing
@testable import NookKit

@Suite("Device-local reading history") @MainActor
struct ReadingHistoryTests {
    private func location() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID()).json") }
    private let first = Date(timeIntervalSince1970: 100)
    private let later = Date(timeIntervalSince1970: 200)

    @Test func onlyExplicitOpenRecordsAnEntry() {
        let file = location(); defer { try? FileManager.default.removeItem(at: file) }
        let store = ReadingHistoryStore(file: file), article = Fixture.article("a", feedID: "f")
        _ = NewsHomeProjection(articles: [article], feeds: [], now: first)
        #expect(store.entries.isEmpty)
        store.recordOpened(article, feed: Fixture.feed("f"), at: first)
        #expect(store.entries.count == 1)
        #expect(store.entries.first?.articleID == article.id)
    }

    @Test func repeatedOpenUpdatesLastWithoutDuplicatingFirst() {
        let file = location(); defer { try? FileManager.default.removeItem(at: file) }
        let store = ReadingHistoryStore(file: file), article = Fixture.article("a", feedID: "f")
        store.recordOpened(article, feed: nil, at: first)
        store.recordOpened(article, feed: nil, at: later)
        #expect(store.entries.count == 1)
        #expect(store.entries[0].firstOpenedAt == first)
        #expect(store.entries[0].lastOpenedAt == later)
    }

    @Test func changedFeedAndArticleIDResolveByCanonicalURL() {
        let file = location(); defer { try? FileManager.default.removeItem(at: file) }
        let store = ReadingHistoryStore(file: file), original = Fixture.article("a", feedID: "f")
        var moved = Fixture.article("other", feedID: "other-feed")
        moved.url = URL(string: original.url.absoluteString + "#section")!
        store.recordOpened(original, feed: nil, at: first)
        store.recordOpened(moved, feed: nil, at: later)
        #expect(store.entries.count == 1)
        #expect(store.entries[0].articleID == moved.id)
        #expect(store.entries[0].firstOpenedAt == first)
    }

    @Test func mostRecentlyOpenedSortsFirst() {
        let file = location(); defer { try? FileManager.default.removeItem(at: file) }
        let store = ReadingHistoryStore(file: file)
        store.recordOpened(Fixture.article("a", feedID: "f"), feed: nil, at: first)
        store.recordOpened(Fixture.article("b", feedID: "f"), feed: nil, at: later)
        #expect(store.entries.map(\.articleID) == ["b", "a"])
        store.recordOpened(Fixture.article("a", feedID: "f"), feed: nil, at: later.addingTimeInterval(1))
        #expect(store.entries.map(\.articleID) == ["a", "b"])
    }

    @Test func reloadRetainsMetadataAndSourceSnapshot() throws {
        let file = location(); defer { try? FileManager.default.removeItem(at: file) }
        let store = ReadingHistoryStore(file: file), feed = Fixture.feed("f")
        var article = Fixture.article("a", feedID: "f")
        article.bodyParagraphs = ["Saved article paragraph."]
        article.contentHTML = "<p>Saved article paragraph.</p>"
        store.recordOpened(article, feed: feed, at: first)
        let reload = ReadingHistoryStore(file: file), entry = try #require(reload.entries.first)
        #expect(entry.title == article.title)
        #expect(entry.source == feed.displayTitle)
        #expect(entry.publishedAt == article.publishedAt)
        #expect(reload.article(for: entry, in: []).bodyParagraphs == article.bodyParagraphs)
        #expect(reload.article(for: entry, in: []).contentHTML == article.contentHTML)
    }

    @Test func reopeningPrefersCurrentArticleAndDoesNotChangeLibraryState() throws {
        let file = location(); defer { try? FileManager.default.removeItem(at: file) }
        let store = ReadingHistoryStore(file: file), original = Fixture.article("a", feedID: "f")
        store.recordOpened(original, feed: nil, at: first)
        var current = original; current.isStarred = true; current.title = "Updated title"
        let reopened = store.article(for: try #require(store.entries.first), in: [current])
        #expect(reopened == current)
        #expect(!original.isStarred)
    }

    @Test func deleteAndClearPersist() throws {
        let file = location(); defer { try? FileManager.default.removeItem(at: file) }
        let store = ReadingHistoryStore(file: file)
        store.recordOpened(Fixture.article("a", feedID: "f"), feed: nil, at: first)
        store.recordOpened(Fixture.article("b", feedID: "f"), feed: nil, at: later)
        store.delete(try #require(store.entries.first).id)
        #expect(ReadingHistoryStore(file: file).entries.map(\.articleID) == ["a"])
        store.clear()
        #expect(ReadingHistoryStore(file: file).entries.isEmpty)
    }

    @Test func equalTitlesDoNotMergeDifferentArticles() {
        let file = location(); defer { try? FileManager.default.removeItem(at: file) }
        let store = ReadingHistoryStore(file: file), a = Fixture.article("a", feedID: "f")
        var b = Fixture.article("b", feedID: "f"); b.title = a.title
        store.recordOpened(a, feed: nil, at: first)
        store.recordOpened(b, feed: nil, at: later)
        #expect(store.entries.count == 2)
    }

    @Test func missingPublishedDateIsOptional() {
        let file = location(); defer { try? FileManager.default.removeItem(at: file) }
        let store = ReadingHistoryStore(file: file)
        var article = Fixture.article("a", feedID: "f"); article.hasExplicitPublishDate = false
        store.recordOpened(article, feed: nil, at: first)
        #expect(store.entries.first?.publishedAt == nil)
    }

    @Test func unreadableArchiveIsNotOverwrittenByAnOpen() throws {
        let file = location(); defer { try? FileManager.default.removeItem(at: file) }
        let corrupt = Data("not JSON".utf8); try corrupt.write(to: file)
        let store = ReadingHistoryStore(file: file)
        store.recordOpened(Fixture.article("a", feedID: "f"), feed: nil)
        #expect(try Data(contentsOf: file) == corrupt)
        #expect(store.errorMessage != nil)
        store.clear()
        #expect(ReadingHistoryStore(file: file).errorMessage == nil)
    }
}
