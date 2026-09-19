import Foundation

/// Immutable, sync-worthy feed fields. User overrides and refresh diagnostics
/// deliberately live outside the content replica.
public struct FeedContent: Codable, Sendable, Equatable {
    public var id: Feed.ID
    public var title: String
    public var siteDescription: String
    public var systemImage: String
    public var feedURL: URL
    public var siteURL: URL

    public init(_ feed: Feed) {
        id = feed.id
        title = feed.title
        siteDescription = feed.siteDescription
        systemImage = feed.systemImage
        feedURL = feed.feedURL
        siteURL = feed.siteURL
    }

    public func makeFeed() -> Feed {
        Feed(
            id: id, title: title, siteDescription: siteDescription,
            category: "Feeds", systemImage: systemImage,
            feedURL: feedURL, siteURL: siteURL, healthScore: 1
        )
    }
}

/// Grow-only article metadata. Read/starred state stays in DeviceStateDocument;
/// the regenerable body stays in a bounded per-device body shard.
public struct ArticleContent: Codable, Sendable, Equatable {
    public var id: Article.ID
    public var feedID: Feed.ID
    public var title: String
    public var summary: String
    public var publishedAt: Date
    public var url: URL
    public var estimatedReadMinutes: Int
    public var newsCategory: NewsCategory?
    public var newsCategoryProvenance: NewsCategoryProvenance?
    public var feedItemGUID: String?
    public var rssTags: [String]
    public var heroImageURL: URL?
    public var heroImageProvenance: HeroImageProvenance?
    public var rssImages: [ArticleImageMetadata]
    public var subtitle: String?
    public var contentSource: ArticleContentSource?
    public var contentQuality: ArticleContentQuality?

    public init(_ article: Article) {
        id = article.id
        feedID = article.feedID
        title = article.title
        summary = article.summary
        publishedAt = article.publishedAt
        url = article.url
        estimatedReadMinutes = article.estimatedReadMinutes
        newsCategory = article.newsCategory
        newsCategoryProvenance = article.newsCategoryProvenance
        feedItemGUID = article.feedItemGUID
        rssTags = article.rssTags
        heroImageURL = article.heroImageURL
        heroImageProvenance = article.heroImageProvenance
        rssImages = article.rssImages
        subtitle = article.subtitle
        contentSource = article.contentSource
        contentQuality = article.contentQuality
    }

    enum CodingKeys: String, CodingKey {
        case id, feedID, title, summary, publishedAt, url, estimatedReadMinutes
        case newsCategory, newsCategoryProvenance, feedItemGUID, rssTags, heroImageURL, heroImageProvenance, rssImages, subtitle, contentSource, contentQuality
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Article.ID.self, forKey: .id)
        feedID = try c.decode(Feed.ID.self, forKey: .feedID)
        title = try c.decode(String.self, forKey: .title)
        summary = try c.decode(String.self, forKey: .summary)
        publishedAt = try c.decode(Date.self, forKey: .publishedAt)
        url = try c.decode(URL.self, forKey: .url)
        estimatedReadMinutes = try c.decode(Int.self, forKey: .estimatedReadMinutes)
        newsCategory = try c.decodeIfPresent(NewsCategory.self, forKey: .newsCategory)
        newsCategoryProvenance = try c.decodeIfPresent(NewsCategoryProvenance.self, forKey: .newsCategoryProvenance)
        feedItemGUID = try c.decodeIfPresent(String.self, forKey: .feedItemGUID)
        rssTags = try c.decodeIfPresent([String].self, forKey: .rssTags) ?? []
        heroImageURL = try c.decodeIfPresent(URL.self, forKey: .heroImageURL)
        heroImageProvenance = try c.decodeIfPresent(HeroImageProvenance.self, forKey: .heroImageProvenance)
        rssImages = try c.decodeIfPresent([ArticleImageMetadata].self, forKey: .rssImages) ?? []
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
        contentSource = try c.decodeIfPresent(ArticleContentSource.self, forKey: .contentSource)
        contentQuality = try c.decodeIfPresent(ArticleContentQuality.self, forKey: .contentQuality)
    }

    public func makeArticle(body: ArticleBody? = nil) -> Article {
        Article(
            id: id, feedID: feedID, title: title, summary: summary,
            bodyParagraphs: body?.bodyParagraphs ?? [], publishedAt: publishedAt,
            url: url, estimatedReadMinutes: estimatedReadMinutes,
            isRead: false, isStarred: false, contentHTML: body?.contentHTML,
            newsCategory: newsCategory,
            newsCategoryProvenance: newsCategoryProvenance,
            feedItemGUID: feedItemGUID,
            rssTags: rssTags,
            heroImageURL: heroImageURL,
            heroImageProvenance: heroImageProvenance,
            rssImages: rssImages,
            subtitle: subtitle,
            contentSource: contentSource,
            contentQuality: contentQuality,
            sourceContents: body?.sourceContents ?? [], document: body?.document
        )
    }
}

/// A state-based content CRDT. Every device publishes only its own file, but
/// republishes the accumulated register set after learning peer state.
public struct ContentShardDocument: Codable, Sendable, Equatable {
    public static let currentSchema = 2

    public var schema: Int
    public var deviceID: String
    public var generation: UInt64
    public var clock: HLC
    public var feeds: [Feed.ID: LWWRegister<FeedContent>]
    public var articles: [Article.ID: LWWRegister<ArticleContent>]

    public init(
        deviceID: String,
        generation: UInt64 = 0,
        clock: HLC = .zero,
        feeds: [Feed.ID: LWWRegister<FeedContent>] = [:],
        articles: [Article.ID: LWWRegister<ArticleContent>] = [:]
    ) {
        schema = Self.currentSchema
        self.deviceID = deviceID
        self.generation = generation
        self.clock = clock
        self.feeds = feeds
        self.articles = articles
    }

    enum CodingKeys: String, CodingKey { case schema, deviceID, generation, clock, feeds, articles }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decodeIfPresent(Int.self, forKey: .schema) ?? Self.currentSchema
        deviceID = try c.decode(String.self, forKey: .deviceID)
        generation = try c.decodeIfPresent(UInt64.self, forKey: .generation) ?? 0
        clock = try c.decodeIfPresent(HLC.self, forKey: .clock) ?? .zero
        feeds = try c.decodeIfPresent([Feed.ID: LWWRegister<FeedContent>].self, forKey: .feeds) ?? [:]
        articles = try c.decodeIfPresent([Article.ID: LWWRegister<ArticleContent>].self, forKey: .articles) ?? [:]
    }

    public func merged(with other: ContentShardDocument, as deviceID: String) -> ContentShardDocument {
        var result = self
        result.deviceID = deviceID
        result.clock = result.clock.witnessed(other.clock)
        for (id, register) in other.feeds {
            result.feeds[id] = result.feeds[id]?.merged(with: register) ?? register
        }
        for (id, register) in other.articles {
            result.articles[id] = result.articles[id]?.merged(with: register) ?? register
        }
        return result
    }

    public func materialize(bodies: [Article.ID: ArticleBody] = [:]) -> ReaderLibrary {
        // Sort by id so the materialized order is deterministic across devices
        // (Dictionary iteration order is not a stable contract), which downstream
        // canonical-alias selection relies on.
        ReaderLibrary(
            feeds: feeds.keys.sorted().map { feeds[$0]!.value.makeFeed() },
            articles: articles.keys.sorted().map { articles[$0]!.value.makeArticle(body: bodies[$0]) },
            lastRefreshedAt: nil,
            folders: []
        )
    }
}

public struct BodyShardDocument: Codable, Sendable, Equatable {
    public static let currentSchema = 2
    public var schema = currentSchema
    public var deviceID: String
    public var generation: UInt64
    public var bodies: [Article.ID: ArticleBody]

    public init(deviceID: String, generation: UInt64 = 0, bodies: [Article.ID: ArticleBody] = [:]) {
        self.deviceID = deviceID
        self.generation = generation
        self.bodies = bodies
    }
}
