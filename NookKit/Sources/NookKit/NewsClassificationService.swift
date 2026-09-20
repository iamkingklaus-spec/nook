import Foundation

/// Local editorial grouping. It never writes feed folders or user category IDs.
public struct NewsClassificationService: Sendable {
    public static let ruleVersion = "news-home-1"

    public struct Classification: Equatable, Sendable {
        public enum Evidence: String, Sendable {
            case existing, feedOverride, rssTag, articlePath, feed, keyword, unknown
        }
        public let category: NewsCategory
        public let provenance: NewsCategoryProvenance?
        public let evidence: Evidence
    }

    public init() {}

    public func classify(_ article: Article, feed: Feed?) -> Classification {
        // Enrichment already carrying provenance is authoritative, including
        // manual choices. A new home rule must not silently erase that work.
        if let category = article.newsCategory, let provenance = article.newsCategoryProvenance {
            return Classification(category: category, provenance: provenance, evidence: .existing)
        }
        if let category = feed?.newsCategoryOverride {
            return result(category, source: .feed, evidence: .feedOverride)
        }
        // Tag order is not significant. Fixed rules resolve ambiguous multi-tags.
        if let category = match(article.rssTags.joined(separator: " ")) {
            return result(category, source: .rssTag, evidence: .rssTag)
        }
        if let category = match(article.url.path.removingPercentEncoding ?? article.url.path) {
            return result(category, source: .rule, evidence: .articlePath)
        }
        if let feed, let category = match(feed.title + " " + (feed.feedURL.host ?? "") + " " + feed.feedURL.path) {
            return result(category, source: .rule, evidence: .feed)
        }
        if let category = match(article.title + " " + article.summary) {
            return result(category, source: .rule, evidence: .keyword)
        }
        // Other is a display fallback, not invented persisted classification.
        return Classification(category: .other, provenance: nil, evidence: .unknown)
    }

    private func result(_ category: NewsCategory, source: NewsCategoryProvenance.Source,
                        evidence: Classification.Evidence) -> Classification {
        Classification(category: category,
                       provenance: .init(source: source, ruleVersion: Self.ruleVersion), evidence: evidence)
    }

    private func match(_ text: String) -> NewsCategory? {
        let normalized = text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
        let padded = " " + normalized + " "
        for (category, terms) in Self.rules {
            if terms.contains(where: { padded.contains(" " + $0 + " ") }) { return category }
        }
        return nil
    }

    // Specific sections precede broad ones. Whole tokens/phrases avoid matches
    // such as "art" in "earth". Intentionally conservative, not an AI classifier.
    private static let rules: [(NewsCategory, [String])] = [
        (.longReads, ["long reads", "long read", "longreads", "longread", "the long read", "长文", "深度报道"]),
        (.technology, ["technology", "tech", "computing", "software", "cybersecurity", "artificial intelligence", "科技", "技术"]),
        (.science, ["science", "scientific", "astronomy", "physics", "biology", "research", "科学"]),
        (.business, ["business", "economy", "economics", "finance", "markets", "financial", "商业", "财经", "经济"]),
        (.culture, ["culture", "arts", "art", "books", "film", "music", "theatre", "文化", "艺术"]),
        (.world, ["world", "international", "politics", "diplomacy", "elections", "全球", "国际"])
    ]
}

public struct NewsPublisher: Hashable, Sendable {
    public let id: String
    public let name: String

    public init(feed: Feed?, articleURL: URL) {
        let host = (feed?.siteURL.host ?? feed?.feedURL.host ?? articleURL.host ?? "")
            .lowercased().replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression)
        func belongs(to domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        if belongs(to: "bbc.com") || belongs(to: "bbc.co.uk") {
            id = "bbc"; name = "BBC"
        } else if belongs(to: "theguardian.com") || belongs(to: "guardian.co.uk") {
            id = "guardian"; name = "The Guardian"
        } else {
            // Keep the full host: guessing the last two components incorrectly
            // merges unrelated co.uk publishers and multi-tenant publications.
            id = host.isEmpty ? (feed?.id ?? articleURL.absoluteString) : host
            name = host.isEmpty ? (feed?.displayTitle ?? "Unknown publisher") : host
        }
    }
}
