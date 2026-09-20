import Foundation

/// For You is a view of the library, never a stored NewsCategory.
public enum NewsHomeSection: Hashable, Sendable {
    case forYou
    case category(NewsCategory)

    public static let navigation: [Self] = [.forYou, .category(.world), .category(.business),
        .category(.technology), .category(.science), .category(.culture), .category(.longReads)]
}

public struct NewsHomeStory: Identifiable, Sendable {
    public var id: Article.ID { article.id }
    public let article: Article
    public let publisher: NewsPublisher
    public let classification: NewsClassificationService.Classification
    public let imageURL: URL?

    public init(article: Article, feed: Feed?) {
        self.article = article
        publisher = NewsPublisher(feed: feed, articleURL: article.url)
        classification = NewsClassificationService().classify(article, feed: feed)
        imageURL = ([article.heroImageURL].compactMap { $0 } + article.rssImages.map(\.url))
            .first { ["https", "http"].contains($0.scheme?.lowercased() ?? "") && $0.host != nil }
    }
}

/// A bounded, pure layout calculation. The caller supplies a read-state snapshot
/// for an edition so reading a story doesn't reshuffle the page on return.
public struct NewsHomeProjection: Sendable {
    public let hero: NewsHomeStory?
    public let primaryStories: [NewsHomeStory]
    public let secondaryStories: [NewsHomeStory]
    public let totalCount: Int
    public var stories: [NewsHomeStory] { [hero].compactMap { $0 } + primaryStories + secondaryStories }

    public init(articles: [Article], feeds: [Feed], section: NewsHomeSection = .forYou,
                readState: [Article.ID: Bool] = [:], now: Date, limit: Int = 100) {
        let feedByID = Dictionary(feeds.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let recentBoundary = now.addingTimeInterval(-24 * 60 * 60)
        func isRecent(_ story: NewsHomeStory) -> Bool { story.article.publishedAt >= recentBoundary }
        func isRead(_ story: NewsHomeStory) -> Bool { readState[story.id] ?? story.article.isRead }
        // Six-hour age bands bound the unread preference; older unread stories
        // can't indefinitely displace fresh read stories. Future dates are capped.
        func band(_ story: NewsHomeStory) -> Int {
            Int(max(0, now.timeIntervalSince(story.article.publishedAt)) / (6 * 60 * 60))
        }
        var seen: Set<Article.ID> = []
        var candidates = articles.filter { seen.insert($0.id).inserted }.map {
            NewsHomeStory(article: $0, feed: feedByID[$0.feedID])
        }.filter { story in
            if case .category(let category) = section { return story.classification.category == category }
            return true
        }.sorted { lhs, rhs in
            if isRecent(lhs) != isRecent(rhs) { return isRecent(lhs) }
            if band(lhs) != band(rhs) { return band(lhs) < band(rhs) }
            if isRead(lhs) != isRead(rhs) { return !isRead(lhs) }
            if lhs.article.publishedAt != rhs.article.publishedAt { return lhs.article.publishedAt > rhs.article.publishedAt }
            return lhs.id < rhs.id
        }
        totalCount = candidates.count
        // Bound layout work. More pages use the same edition date/read snapshot.
        candidates = Array(candidates.prefix(max(1, limit) + 12))
        var ordered: [NewsHomeStory] = []
        if let first = candidates.first {
            let index = candidates.prefix(6).firstIndex {
                band($0) == band(first) && isRecent($0) == isRecent(first)
                    && isRead($0) == isRead(first) && $0.imageURL != nil
            } ?? 0
            ordered.append(candidates.remove(at: index))
        }
        while !candidates.isEmpty && ordered.count < max(1, limit) {
            var index = 0
            if section == .forYou, let previous = ordered.last, let first = candidates.first {
                // Only rotate within the same freshness tier. Limited lookahead
                // keeps diversity from pulling stale articles above today's news.
                let eligible = candidates.indices.prefix(12).filter { isRecent(candidates[$0]) == isRecent(first) }
                func penalty(_ i: Int) -> Int {
                    i + (candidates[i].publisher.id == previous.publisher.id ? 12 : 0)
                        + (candidates[i].classification.category == previous.classification.category ? 3 : 0)
                }
                index = eligible.min { penalty($0) < penalty($1) } ?? 0
            }
            ordered.append(candidates.remove(at: index))
        }
        hero = ordered.first
        primaryStories = Array(ordered.dropFirst().prefix(4))
        secondaryStories = Array(ordered.dropFirst(5))
    }
}

/// Refresh diagnostics for a non-blocking home message. Cancelled/unattempted
/// feeds are not failures, and an all-failed refresh has no new success date.
public struct NewsRefreshOutcome: Equatable, Sendable {
    public let succeeded: Int
    public let failed: Int
    public let completedAt: Date
    public var successfulAt: Date? { succeeded > 0 ? completedAt : nil }

    public init(succeeded: Int, failed: Int, completedAt: Date) {
        self.succeeded = succeeded; self.failed = failed; self.completedAt = completedAt
    }
}
