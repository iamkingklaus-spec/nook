import Foundation
import Testing
import NookKit // Deliberately no @testable: same access boundary as NookiOS.

@Suite("Reading history across the app module boundary") @MainActor
struct ReadingHistoryPublicAPITests {
    @Test func archivedHistoryCanBeSearchedAndReopenedUsingPublicLibrary() throws {
        let id = UUID().uuidString
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("history-public-\(id).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = ReaderStore.shared
        let history = ReadingHistoryStore(file: file)
        let article = Article(id: id, feedID: "archived-feed", title: "Archived reporting \(id)", summary: "Context",
            bodyParagraphs: ["An archived article remains readable."], publishedAt: .now,
            url: URL(string: "https://example.com/\(id)")!, estimatedReadMinutes: 1, isRead: false, isStarred: false)
        history.recordOpened(article, feed: nil)
        let entry = try #require(history.search(id, excluding: store.libraryArticles).first)
        let reopened = history.article(for: entry, in: store.libraryArticles)
        #expect(reopened.id == id)
        #expect(reopened.title == article.title)
        #expect(reopened.bodyParagraphs == article.bodyParagraphs)
        // A current library copy wins over the archived snapshot and does not
        // also appear in the separate history search section.
        var current = article
        current.title = "Updated reporting"
        #expect(history.search(id, excluding: [current]).isEmpty)
        #expect(history.article(for: entry, in: [current]).title == current.title)
    }
}
