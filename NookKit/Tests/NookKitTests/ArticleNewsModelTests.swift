import Foundation
import Testing
@testable import NookKit

enum NewsFixture {
    static func article() -> Article {
        var article = Fixture.article("story", feedID: "feed")
        article.newsCategory = .technology
        article.newsCategoryProvenance = .init(source: .rule, ruleVersion: "news-rules-1")
        article.feedItemGUID = "urn:story:opaque?id=1&lang=en"
        article.rssTags = ["AI", "世界"]
        article.heroImageURL = URL(string: "https://example.com/hero.jpg")!
        article.heroImageProvenance = .mediaContent
        article.rssImages = [.init(url: article.heroImageURL!, provenance: .mediaContent, mimeType: "image/jpeg")]
        article.subtitle = "A subtitle"
        article.contentSource = .rssFullContent
        article.contentQuality = .complete
        article.bodyParagraphs = ["First paragraph", "Second paragraph"]
        article.contentHTML = "<p>First paragraph</p><p>Second paragraph</p>"
        article.sourceContents = [
            .init(source: .rssFullContent, content: article.contentHTML!, format: .html, sourceElement: "content:encoded"),
            .init(source: .rssDescription, content: "Short summary", format: .plainText, sourceElement: "description", quality: .partial),
            .init(source: .extractedReaderContent, content: "Extracted body", format: .plainText, quality: .complete)
        ]
        article.document = ArticleDocument(source: .rssFullContent, blocks: article.bodyParagraphs.map {
            ArticleBlock(kind: .paragraph, sourceContent: $0)
        })
        return article
    }

    static let legacyArticle = Data(#"{"id":"old","feedID":"feed","title":"Old","summary":"Summary","publishedAt":0,"url":"https://example.com/old","estimatedReadMinutes":1,"isRead":true,"isStarred":false}"#.utf8)
    static let legacyContent = Data(#"{"id":"old","feedID":"feed","title":"Old","summary":"Summary","publishedAt":0,"url":"https://example.com/old","estimatedReadMinutes":1}"#.utf8)
}

@Suite("Article news data model")
struct ArticleNewsModelTests {
    @Test("Old Article and ArticleContent payloads decode with empty news defaults")
    func legacyDecoding() throws {
        let decoder = JSONDecoder()
        for article in [try decoder.decode(Article.self, from: NewsFixture.legacyArticle),
                        try decoder.decode(ArticleContent.self, from: NewsFixture.legacyContent).makeArticle()] {
            #expect(article.newsCategory == nil)
            #expect(article.newsCategoryProvenance == nil)
            #expect(article.feedItemGUID == nil)
            #expect(article.rssTags.isEmpty)
            #expect(article.heroImageURL == nil)
            #expect(article.heroImageProvenance == nil)
            #expect(article.rssImages.isEmpty)
            #expect(article.subtitle == nil)
            #expect(article.contentSource == nil)
            #expect(article.contentQuality == nil)
            #expect(article.sourceContents.isEmpty)
            #expect(article.document == nil)
        }
    }

    @Test("Legacy inline bodies remain readable")
    func legacyInlineAndBody() throws {
        let bodyJSON = Data(#"{"bodyParagraphs":["Old paragraph"],"contentHTML":"<p>Old paragraph</p>"}"#.utf8)
        let body = try JSONDecoder().decode(ArticleBody.self, from: bodyJSON)
        #expect(body.bodyParagraphs == ["Old paragraph"])
        #expect(body.sourceContents.isEmpty)
        #expect(body.document == nil)
        var old = try #require(try JSONSerialization.jsonObject(with: NewsFixture.legacyArticle) as? [String: Any])
        old["bodyParagraphs"] = body.bodyParagraphs
        old["contentHTML"] = body.contentHTML
        let article = try JSONDecoder().decode(Article.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(article.body == body)
        #expect(article.isRead)
    }

    @Test("Article JSON preserves all new fields")
    func articleRoundTrip() throws {
        let article = NewsFixture.article()
        let decoded = try JSONDecoder().decode(Article.self, from: JSONEncoder().encode(article))
        #expect(decoded == article)
    }

    @Test("ArticleContent plus its body round-trip keeps every news and document field")
    func contentRoundTrip() throws {
        let article = NewsFixture.article()
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let content = try decoder.decode(ArticleContent.self, from: encoder.encode(ArticleContent(article)))
        let body = try decoder.decode(ArticleBody.self, from: encoder.encode(article.body))
        #expect(content.makeArticle(body: body) == article)
        #expect(content.makeArticle().document == nil)
        #expect(content.makeArticle().sourceContents.isEmpty)
        #expect(content.makeArticle().heroImageURL == article.heroImageURL)
    }

    @Test("List-light encoding strips new heavy fields and hydration restores them")
    func lightBaseline() throws {
        let article = NewsFixture.article()
        let encoder = JSONEncoder()
        encoder.userInfo[.stripArticleContent] = true
        let data = try encoder.encode(article)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["document"] == nil)
        #expect(json["sourceContents"] == nil)
        #expect(json["contentHTML"] == nil)
        var restored = try JSONDecoder().decode(Article.self, from: data)
        #expect(!restored.hasBody)
        restored.applyBody(article.body)
        #expect(restored == article)
    }

    @Test("A source/document-only article is retained as body data")
    func bodyPresence() {
        var article = Fixture.article("a", feedID: "f")
        #expect(!article.hasBody)
        article.document = NewsFixture.article().document
        #expect(article.hasBody)
        article.document = nil
        article.sourceContents = NewsFixture.article().sourceContents
        #expect(article.hasBody)
    }

    @Test("News categories never become user category IDs or feed folders")
    func categoriesStayIndependent() throws {
        let article = NewsFixture.article()
        var state = DeviceStateDocument(deviceID: "user")
        state.setCategory("custom-id", ArticleCategory(id: "custom-id", name: "Mine"), hlc: Fixture.hlc(1))
        state.setArticleCategories(article.id, ["custom-id"], hlc: Fixture.hlc(1))
        state.setFeedCategory(article.feedID, "My folder", hlc: Fixture.hlc(2))
        let base = Fixture.library(feeds: [Fixture.feed(article.feedID)], articles: [article])
        let merged = DeviceStateDocument.materialize(base: base, shards: [state])
        let result = try #require(merged.articles.first)
        #expect(result.newsCategory == .technology)
        #expect(result.categories == ["custom-id"])
        #expect(result.rssTags == ["AI", "世界"])
        #expect(merged.feeds.first?.category == "My folder")
        #expect(ArticleContent(result).makeArticle().categories.isEmpty)
        #expect(NewsCategory.allCases.map(\.rawValue) == ["world", "business", "technology", "science", "culture", "longReads", "other"])
    }

    @Test("Unchanged RSS retains enrichment; changed source invalidates its document")
    func refreshEnrichment() {
        let old = NewsFixture.article()
        var fresh = old
        fresh.newsCategory = nil
        fresh.newsCategoryProvenance = nil
        fresh.document = nil
        fresh.contentQuality = .unknown
        fresh.sourceContents.removeAll { $0.source == .extractedReaderContent }
        fresh.preserveNewsEnrichment(from: old)
        #expect(fresh.newsCategory == old.newsCategory)
        #expect(fresh.newsCategoryProvenance == old.newsCategoryProvenance)
        #expect(fresh.sourceContents == old.sourceContents)
        #expect(fresh.document == old.document)
        #expect(fresh.contentQuality == .complete)
        fresh.document = nil
        fresh.sourceContents[0].content = "Changed feed body"
        fresh.contentQuality = .unknown
        fresh.preserveNewsEnrichment(from: old)
        #expect(fresh.document == nil)
        #expect(fresh.contentQuality == .unknown)
    }

    @Test("Reader-extracted documents and explicit manual heroes survive RSS refresh")
    func extractedEnrichment() {
        var old = NewsFixture.article()
        old.heroImageProvenance = .manual
        old.document = ArticleDocument(source: .extractedReaderContent,
                                       blocks: [.init(kind: .paragraph, sourceContent: "Extracted body")])
        var fresh = Fixture.article(old.id, feedID: old.feedID)
        fresh.heroImageURL = URL(string: "https://example.com/new.jpg")
        fresh.heroImageProvenance = .enclosure
        fresh.preserveNewsEnrichment(from: old)
        #expect(fresh.heroImageURL == old.heroImageURL)
        #expect(fresh.heroImageProvenance == .manual)
        #expect(fresh.document == old.document)
    }
}

@Suite("Article document identity")
struct ArticleDocumentTests {
    private let a = ArticleBlock(kind: .paragraph, sourceContent: "A 世界")
    private let b = ArticleBlock(kind: .heading, sourceContent: "B")

    @Test("IDs and hashes survive round-trip and insertion of unrelated blocks")
    func stableIdentity() throws {
        let original = ArticleDocument(source: .rssFullContent, blocks: [a, b])
        let decoded = try JSONDecoder().decode(ArticleDocument.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
        let inserted = ArticleDocument(source: .rssFullContent, blocks: [.init(kind: .quote, sourceContent: "New"), a, b])
        #expect(Array(inserted.blocks.dropFirst().map(\.id)) == original.blocks.map(\.id))
        #expect(inserted.documentHash != original.documentHash)
        #expect(original.schemaVersion == 1)
        #expect(a.contentHash == "14678ac9cac381d3fca16d88c8eab686c70ff080815340b65344893b48140246")
    }

    @Test("Duplicate text has unique deterministic IDs; order changes the document hash")
    func duplicatesAndOrder() {
        let document = ArticleDocument(source: .rssFullContent, blocks: [a, a, b])
        #expect(Set(document.blocks.map(\.id)).count == 3)
        #expect(document.blocks[0].contentHash == document.blocks[1].contentHash)
        #expect(document.blocks[1].occurrence == 1)
        let moved = ArticleDocument(source: .rssFullContent, blocks: [b, a, a])
        #expect(Set(moved.blocks.map(\.id)) == Set(document.blocks.map(\.id)))
        #expect(moved.documentHash != document.documentHash)
    }

    @Test("Text, kind, format and document source affect identity")
    func identityInputs() {
        #expect(a.id != ArticleBlock(kind: .paragraph, sourceContent: "A changed").id)
        #expect(a.id != ArticleBlock(kind: .heading, sourceContent: a.sourceContent).id)
        #expect(a.id != ArticleBlock(kind: .paragraph, sourceContent: a.sourceContent, format: .html).id)
        #expect(ArticleDocument(source: .rssFullContent, blocks: [a]).documentHash
                != ArticleDocument(source: .extractedReaderContent, blocks: [a]).documentHash)
    }

    @Test("Serialized stale hashes are recomputed from the source")
    func hashesAreDerived() throws {
        let data = Data(#"{"source":"rssDescription","blocks":[{"kind":"paragraph","sourceContent":"original","id":"stale","contentHash":"stale"}],"documentHash":"stale"}"#.utf8)
        let document = try JSONDecoder().decode(ArticleDocument.self, from: data)
        #expect(document.schemaVersion == 1)
        #expect(document.blocks[0].id != "stale")
        #expect(document.documentHash != "stale")
    }
}
