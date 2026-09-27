import Foundation
import Observation

public struct ReadingHistoryEntry: Codable, Identifiable, Sendable {
    public let id: String
    public var articleID: Article.ID
    public var canonicalURL: URL
    public var title: String
    public var feedID: Feed.ID
    public var source: String
    public var publishedAt: Date?
    public let firstOpenedAt: Date
    public var lastOpenedAt: Date
    // Content-only fallback, not a second copy of read/star/category state. It
    // lets the Reader reuse caches by article ID after a feed drops an old item.
    public var snapshot: ArticleContent?
}

/// Device-only history, deliberately outside ReaderLibrary/replicas/shards.
/// Only Reader entry points call recordOpened; projections never write history.
@MainActor @Observable
public final class ReadingHistoryStore {
    public static let shared = ReadingHistoryStore()
    public private(set) var entries: [ReadingHistoryEntry] = []
    public private(set) var errorMessage: String?
    @ObservationIgnored private let file: URL?
    @ObservationIgnored private var readable = true
    private struct Archive: Codable {
        var version = 1 // Reserved for future progress/read-state fields.
        var entries: [ReadingHistoryEntry]
    }

    public init(file: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first?.appendingPathComponent("Nook/ReadingHistory/history.json")) {
        self.file = file
        guard let file, FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: file))
            guard archive.version == 1 else { throw CocoaError(.fileReadUnknown) }
            entries = Self.sorted(archive.entries)
        } catch {
            readable = false // Preserve an unreadable file until explicit Clear.
            errorMessage = "无法读取本地阅读历史；原文件未覆盖。"
        }
    }

    public func recordOpened(_ article: Article, feed: Feed?, at date: Date = .now) {
        guard readable else { return }
        var next = entries
        let key = StableArticleIdentity.key(article)
        let index = next.firstIndex { $0.id == key || $0.canonicalURL == StableArticleIdentity.canonicalURL(article.url) }
            ?? next.firstIndex { $0.articleID == article.id }
        let old = index.map { next[$0] }
        let value = ReadingHistoryEntry(id: old?.id ?? key, articleID: article.id,
            canonicalURL: StableArticleIdentity.canonicalURL(article.url), title: article.title,
            feedID: article.feedID, source: feed?.displayTitle ?? old?.source ?? article.url.host() ?? "",
            publishedAt: article.hasExplicitPublishDate ? article.publishedAt : old?.publishedAt,
            firstOpenedAt: old?.firstOpenedAt ?? date, lastOpenedAt: max(old?.lastOpenedAt ?? date, date),
            snapshot: ArticleContent(article))
        if let index { next[index] = value } else { next.append(value) }
        save(next)
    }

    public func delete(_ id: String) {
        guard readable else { return }
        save(entries.filter { $0.id != id })
    }
    public func clear() { save([]) }

    public func article(for entry: ReadingHistoryEntry, in articles: [Article]) -> Article {
        if let current = articles.first(where: { $0.id == entry.articleID })
            ?? articles.first(where: { StableArticleIdentity.canonicalURL($0.url) == entry.canonicalURL }) { return current }
        if let snapshot = entry.snapshot { return snapshot.makeArticle() }
        return Article(id: entry.articleID, feedID: entry.feedID, title: entry.title, summary: "",
            bodyParagraphs: [], publishedAt: entry.publishedAt ?? entry.firstOpenedAt, url: entry.canonicalURL,
            estimatedReadMinutes: 0, isRead: false, isStarred: false,
            hasExplicitPublishDate: entry.publishedAt != nil)
    }

    private static func sorted(_ values: [ReadingHistoryEntry]) -> [ReadingHistoryEntry] {
        values.sorted { $0.lastOpenedAt == $1.lastOpenedAt ? $0.id < $1.id : $0.lastOpenedAt > $1.lastOpenedAt }
    }

    private func save(_ values: [ReadingHistoryEntry]) {
        do {
            guard let file else { throw CocoaError(.fileNoSuchFile) }
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let sorted = Self.sorted(values)
            try JSONEncoder().encode(Archive(entries: sorted)).write(to: file, options: .atomic)
            entries = sorted
            readable = true
            errorMessage = nil
        } catch { errorMessage = "阅读历史保存失败；请检查本机存储空间。" }
    }
}
