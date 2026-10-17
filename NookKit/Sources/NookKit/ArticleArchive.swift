import Foundation
import Observation

public enum ArticleArchivePolicy {
    public static let retention: TimeInterval = 90 * 24 * 60 * 60
    public static let searchDebounce: Duration = .milliseconds(220)
}

/// A local index over existing article identities, never a second content/cache store.
public struct ArticleArchiveEntry: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public var content: ArticleContent
    public var source: String
    public var sourceFeedID: Feed.ID?
    public var categories: [String]
    public var hasExplicitPublishDate: Bool
    public let firstSeenAt: Date
    public var lastSeenAt: Date
    public var isRead: Bool
    public var isSaved: Bool
    public var canonicalURL: URL { StableArticleIdentity.canonicalURL(content.url) }
    public var contentCacheReference: String { content.id }

    public func article() -> Article {
        var value = content.makeArticle()
        value.categories = categories
        value.hasExplicitPublishDate = hasExplicitPublishDate
        value.isRead = isRead
        value.isStarred = isSaved
        return value
    }
}

public struct ArchiveSearchFilter: Equatable, Sendable {
    public enum State: String, CaseIterable, Sendable { case all, unread, read, saved }
    public var state: State = .all
    public var source: String?
    public var publishedAfter: Date?
    public init() {}
}

@MainActor @Observable
public final class ArticleArchiveStore {
    public private(set) var entries: [String: ArticleArchiveEntry] = [:]
    public private(set) var errorMessage: String?
    /// Only successful RSS responses replace membership; failures never empty it.
    public private(set) var currentByFeed: [Feed.ID: Set<String>] = [:]
    @ObservationIgnored private var retired: Set<String> = []
    @ObservationIgnored private var index: [String: String] = [:]
    @ObservationIgnored private let file: URL?
    @ObservationIgnored private var readable = true
    private struct File: Codable {
        var version = 1
        var entries: [String: ArticleArchiveEntry]
        var currentByFeed: [Feed.ID: Set<String>]
        var retired: Set<String>
    }

    public init(file: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first?.appendingPathComponent("Nook/Archive/index.json")) {
        self.file = file
        guard let file, FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let value = try JSONDecoder().decode(File.self, from: Data(contentsOf: file))
            guard value.version == 1 else { throw CocoaError(.fileReadUnknown) }
            entries = value.entries; currentByFeed = value.currentByFeed; retired = value.retired
            rebuildIndex()
        } catch { readable = false; errorMessage = "无法读取本地 Archive；原文件未覆盖。" }
    }

    /// Seeds legacy/peer metadata once, without making old records freshly seen
    /// at every launch. The synchronized grow-only content replica is untouched.
    public func synchronize(_ articles: [Article], feeds: [Feed], at now: Date = .now) {
        guard readable else { return }
        let sources = Dictionary(feeds.map { ($0.id, $0.displayTitle) }, uniquingKeysWith: { a, _ in a })
        var changed = false
        for id in Array(currentByFeed.keys) where sources[id] == nil && currentByFeed[id]?.isEmpty == false {
            currentByFeed[id] = []; changed = true
        }
        for (key, aliases) in Dictionary(grouping: articles, by: StableArticleIdentity.key) {
            let ordered = aliases.sorted { $0.id < $1.id }
            guard var article = ordered.first(where: { $0.id == entries[key]?.content.id }) ?? ordered.first else { continue }
            article.isRead = aliases.contains(where: \.isRead)
            article.isStarred = aliases.contains(where: \.isStarred)
            article.categories = Array(Set(aliases.flatMap(\.categories))).sorted()
            guard !retired.contains(key) || article.isStarred else { continue }
            let old = entries[key]
            let value = entry(article, source: sources[article.feedID], at: old?.lastSeenAt ?? now)
            if old != value { entries[key] = value; changed = true }
        }
        if changed { persist() }
    }

    public func sawFeed(_ feed: Feed, articles: [Article], at now: Date = .now) {
        guard readable else { return }
        currentByFeed[feed.id] = Set(articles.map(StableArticleIdentity.key))
        for article in articles {
            let key = StableArticleIdentity.key(article)
            retired.remove(key)
            entries[key] = entry(article, source: feed.displayTitle, at: now)
        }
        persist()
    }

    public func isCurrent(_ article: Article) -> Bool {
        if ReaderStore.isManagedFeed(article.feedID) { return false }
        // Unknown membership means this feed hasn't been fetched since migration.
        guard let members = currentByFeed[article.feedID] else { return true }
        return members.contains(StableArticleIdentity.key(article))
    }

    public func updateState(_ article: Article) {
        guard readable else { return }
        let key = StableArticleIdentity.key(article)
        guard entries[key] != nil || article.isStarred else { return }
        entries[key] = entry(article, source: entries[key]?.source, at: entries[key]?.lastSeenAt ?? .now)
        if article.isStarred { retired.remove(key) }
        persist()
    }

    /// Retention affects this local search index only. Never delete bodies,
    /// replicas, history, vocabulary, annotations or saved state here.
    public func prune(at now: Date = .now, protectedURLs: Set<URL> = []) {
        guard readable else { return }
        let protected = Set(protectedURLs.map(StableArticleIdentity.canonicalURL))
        let current = Set(currentByFeed.values.flatMap { $0 })
        let expired = entries.values.filter {
            !$0.isSaved && !current.contains($0.id) && !protected.contains($0.canonicalURL) &&
            now.timeIntervalSince($0.lastSeenAt) >= ArticleArchivePolicy.retention
        }.map(\.id)
        guard !expired.isEmpty else { return }
        for id in expired { entries[id] = nil; retired.insert(id) }
        persist()
    }

    public func forget(_ article: Article) {
        guard readable else { return }
        let key = StableArticleIdentity.key(article)
        entries[key] = nil; retired.insert(key)
        for feed in Array(currentByFeed.keys) { currentByFeed[feed]?.remove(key) }
        persist()
    }

    /// Called only after LocalAppResetService removed the device directory.
    public func didResetLocalData() {
        entries = [:]; currentByFeed = [:]; retired = []; index = [:]
        readable = true; errorMessage = nil
    }

    public func search(_ query: String, filter: ArchiveSearchFilter = .init(),
                       history: [ReadingHistoryEntry] = []) -> [ArticleArchiveEntry] {
        // Persisted archive metadata supplies summary/source; old history files
        // remain searchable even when they predate this index or its retention.
        var values = entries
        for item in history where values[item.id] == nil {
            let article = item.snapshot?.makeArticle() ?? Article(id: item.articleID, feedID: item.feedID,
                title: item.title, summary: "", bodyParagraphs: [], publishedAt: item.publishedAt ?? item.firstOpenedAt,
                url: item.canonicalURL, estimatedReadMinutes: 0, isRead: true, isStarred: false)
            let key = StableArticleIdentity.key(article)
            guard values[key] == nil else { continue }
            values[key] = ArticleArchiveEntry(id: key, content: ArticleContent(article), source: item.source,
                sourceFeedID: ReaderStore.isManagedFeed(item.feedID) ? nil : item.feedID,
                categories: [], hasExplicitPublishDate: item.publishedAt != nil,
                firstSeenAt: item.firstOpenedAt, lastSeenAt: item.lastOpenedAt, isRead: true, isSaved: false)
        }
        let words = Self.normalized(query).split(whereSeparator: \.isWhitespace)
        return values.values.filter { value in
            let text = index[value.id] ?? Self.searchText(value)
            return words.allSatisfy { text.contains($0) } &&
                (filter.source == nil || filter.source == value.source) &&
                (filter.publishedAfter == nil || (value.hasExplicitPublishDate && value.content.publishedAt >= filter.publishedAfter!)) &&
                (filter.state == .all || (filter.state == .read && value.isRead) ||
                 (filter.state == .unread && !value.isRead) || (filter.state == .saved && value.isSaved))
        }.sorted {
            $0.content.publishedAt == $1.content.publishedAt ? $0.id < $1.id : $0.content.publishedAt > $1.content.publishedAt
        }
    }

    private func entry(_ article: Article, source: String?, at date: Date) -> ArticleArchiveEntry {
        let key = StableArticleIdentity.key(article), old = entries[key]
        // Keep the first local article ID as the cache association when another
        // RSS feed carries the same URL. No title-based deduplication.
        var content = ArticleContent(article)
        content.id = old?.content.id ?? article.id
        return ArticleArchiveEntry(id: key, content: content,
            source: (ReaderStore.isManagedFeed(article.feedID) ? article.url.host() : source) ?? old?.source ?? article.url.host() ?? "",
            sourceFeedID: ReaderStore.isManagedFeed(article.feedID) ? nil : article.feedID,
            categories: article.categories, hasExplicitPublishDate: article.hasExplicitPublishDate,
            firstSeenAt: old?.firstSeenAt ?? date, lastSeenAt: max(old?.lastSeenAt ?? date, date),
            isRead: article.isRead, isSaved: article.isStarred)
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    private static func searchText(_ entry: ArticleArchiveEntry) -> String {
        normalized(entry.content.title + " " + entry.source + " " + entry.content.summary)
    }
    private func rebuildIndex() { index = entries.mapValues(Self.searchText) }
    private func persist() {
        rebuildIndex()
        guard let file else { return } // In-memory test instance.
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(File(entries: entries, currentByFeed: currentByFeed, retired: retired))
                .write(to: file, options: .atomic)
            errorMessage = nil
        } catch { errorMessage = "Archive 保存失败；请检查本机存储空间。" }
    }
}
