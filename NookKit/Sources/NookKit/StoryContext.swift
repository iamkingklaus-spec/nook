import Foundation

/// A local, derived relationship, never stored in Article or replicated user state.
public struct EventCluster: Equatable, Sendable {
    public let members: [Article]
    public var fingerprint: String {
        ArticleDocument.digest(["event-cluster-v1"] + members.sorted { $0.id < $1.id }.map {
            ArticleDocument.digest([StableArticleIdentity.canonicalURL($0.url).absoluteString,
                $0.id, $0.title, $0.summary, String($0.hasExplicitPublishDate), String($0.publishedAt.timeIntervalSince1970),
                $0.document?.documentHash ?? ""])
        })
    }
    public func related(to article: Article) -> [Article] {
        members.filter { $0.id != article.id && StableArticleIdentity.canonicalURL($0.url) != StableArticleIdentity.canonicalURL(article.url)
            && StoryClustering.publisher($0) != StoryClustering.publisher(article) }
    }
}

public enum StoryClustering {
    public static let window: TimeInterval = 72 * 3600
    public static let maximumCandidates = 300
    private static let stop = Set("a an the of to in on at for and or as is are was were be been being with by from it its this that new says said say after before over more news live update updates latest report reports about how why what has have had will would could into than amid".split(separator: " ").map(String.init))

    static func tokens(_ text: String) -> Set<String> {
        Set(text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && !stop.contains($0) })
    }
    static func publisher(_ article: Article) -> String {
        (article.url.host ?? article.feedID).lowercased().replacingOccurrences(of: "www.", with: "")
    }
    public static func candidates(for article: Article, in articles: [Article]) -> [Article] {
        var seen = Set<URL>()
        return Array(articles.filter { abs($0.publishedAt.timeIntervalSince(article.publishedAt)) <= window }
            .sorted {
                let a = abs($0.publishedAt.timeIntervalSince(article.publishedAt))
                let b = abs($1.publishedAt.timeIntervalSince(article.publishedAt))
                return a == b ? $0.id < $1.id : a < b
            }.filter { seen.insert(StableArticleIdentity.canonicalURL($0.url)).inserted }
            .prefix(maximumCandidates))
    }
    /// Anchor comparisons only, not transitive topic grouping or historical all-pairs.
    public static func cluster(for article: Article, candidates: [Article]) -> EventCluster? {
        let others = candidates.filter { sameEvent(article, $0) }.sorted {
            $0.publishedAt == $1.publishedAt ? $0.id < $1.id : $0.publishedAt > $1.publishedAt
        }
        guard !others.isEmpty else { return nil }
        return EventCluster(members: [article] + Array(others.prefix(12)))
    }
    static func sameEvent(_ a: Article, _ b: Article) -> Bool {
        guard a.id != b.id, StableArticleIdentity.canonicalURL(a.url) != StableArticleIdentity.canonicalURL(b.url),
              publisher(a) != publisher(b), abs(a.publishedAt.timeIntervalSince(b.publishedAt)) <= window else { return false }
        let x = tokens(a.title), y = tokens(b.title), shared = x.intersection(y)
        guard shared.count >= 3 else { return false }
        let titleOverlap = Double(shared.count) / Double(max(1, min(x.count, y.count)))
        let jaccard = Double(shared.count) / Double(max(1, x.union(y).count))
        let sx = tokens(String(a.summary.prefix(1200))), sy = tokens(String(b.summary.prefix(1200)))
        let summaryOverlap = Double(sx.intersection(sy).count) / Double(max(1, min(sx.count, sy.count)))
        // Rare/specific title tokens act as entity/event cues; a company name alone is insufficient.
        let specific = shared.filter { $0.count >= 5 || $0.allSatisfy(\.isNumber) }.count
        let proximity = 1 - abs(a.publishedAt.timeIntervalSince(b.publishedAt)) / window
        let score = 0.55 * titleOverlap + 0.25 * min(summaryOverlap, 1) + 0.15 * min(Double(specific) / 3, 1) + 0.05 * proximity
        return titleOverlap >= 0.6 && jaccard >= 0.38 && specific >= 2
            && (summaryOverlap >= 0.15 || shared.count >= 5) && score >= 0.67
    }
}
