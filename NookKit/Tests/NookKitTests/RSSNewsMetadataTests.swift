import Foundation
import Testing
@testable import NookKit

@Suite("RSS and Atom news metadata")
struct RSSNewsMetadataTests {
    private func parse(_ xml: String) throws -> Article {
        let feed = try FeedXMLParser(feedURL: URL(string: "https://example.com/feeds/news.xml")!).parse(data: Data(xml.utf8))
        return try #require(feed.articles.first)
    }

    @Test("RSS keeps tags, GUID, all image sources, and separate untruncated content payloads")
    func rssEvidence() throws {
        let article = try parse("""
        <rss xmlns:content="http://purl.org/rss/1.0/modules/content/" xmlns:media="http://search.yahoo.com/mrss/">
        <channel><title>News</title><category>Feed only</category><item>
          <title>Story</title><link>https://example.com/story</link>
          <guid isPermaLink="false">opaque:1&amp;two</guid><subtitle>A deck</subtitle>
          <category>Science</category><category>世界</category><category>Science</category>
          <description><![CDATA[<p>Short <em>summary</em>.</p>]]></description>
          <content:encoded><![CDATA[<p>Full article &amp; markup.</p>]]></content:encoded>
          <media:group><media:thumbnail url="../thumb.jpg"/><media:content url="../large.jpg" medium="image" type="image/jpeg"/></media:group>
          <enclosure url="https://example.com/enclosed.jpg" type="image/jpeg"/>
          <enclosure url="https://example.com/audio.mp3" type="audio/mpeg"/>
          <source><category>Ignore nested</category></source>
        </item></channel></rss>
        """)
        #expect(article.feedItemGUID == "opaque:1&two")
        #expect(article.rssTags == ["Science", "世界"])
        #expect(article.newsCategory == nil)
        #expect(article.categories.isEmpty)
        #expect(article.subtitle == "A deck")
        #expect(article.rssImages.map(\.provenance) == [.mediaThumbnail, .mediaContent, .enclosure])
        #expect(article.rssImages[0].url.absoluteString == "https://example.com/thumb.jpg")
        #expect(article.heroImageURL?.absoluteString == "https://example.com/enclosed.jpg")
        #expect(article.heroImageProvenance == .enclosure)
        #expect(article.contentSource == .rssFullContent)
        #expect(article.contentQuality == .unknown)
        #expect(article.sourceContents.map(\.source) == [.rssFullContent, .rssDescription])
        #expect(article.sourceContents[0].sourceElement == "content:encoded")
        #expect(article.sourceContents[0].content == "<p>Full article &amp; markup.</p>")
        #expect(article.sourceContents[1].content == "<p>Short <em>summary</em>.</p>")
        #expect(article.sourceContents.allSatisfy { $0.format == .html })
        let restored = try JSONDecoder().decode(Article.self, from: JSONEncoder().encode(article))
        #expect(ArticleContent(restored) == ArticleContent(article))
        #expect(restored.body == article.body)
    }

    @Test("Atom category terms, opaque IDs, summary type and image enclosures survive")
    func atomEvidence() throws {
        let article = try parse("""
        <feed xmlns="http://www.w3.org/2005/Atom"><title>Feed</title>
        <entry><title>Story</title><id>urn:uuid:opaque</id>
          <category term="technology" label="Technology"/><category term="AI"/>
          <source><category term="not-an-entry-tag"/></source>
          <link rel="alternate" href="https://example.com/story"/>
          <link rel="enclosure" href="/cover.png" type="image/png"/>
          <summary type="html">&lt;p&gt;Summary &amp;amp; more&lt;/p&gt;</summary>
        </entry></feed>
        """)
        #expect(article.feedItemGUID == "urn:uuid:opaque")
        #expect(article.rssTags == ["technology", "AI"])
        #expect(article.url.absoluteString == "https://example.com/story")
        #expect(article.heroImageURL?.absoluteString == "https://example.com/cover.png")
        #expect(article.heroImageProvenance == .enclosure)
        #expect(article.contentSource == .rssDescription)
        #expect(article.sourceContents.first?.sourceElement == "summary")
        #expect(article.contentHTML == "<p>Summary &amp; more</p>")
    }

    @Test("Namespace aliases and xml:base retain image evidence")
    func namespaceAliases() throws {
        let article = try parse("""
        <rss xmlns:m="http://search.yahoo.com/mrss/" xmlns:c="http://purl.org/rss/1.0/modules/content/">
        <channel><title>Feed</title><item xml:base="https://cdn.example.com/images/">
        <title>Story</title><c:encoded><![CDATA[<p>Body</p>]]></c:encoded>
        <m:content url="hero.webp" medium="image"/><m:thumbnail url="thumb.webp"/>
        </item></channel></rss>
        """)
        #expect(article.heroImageURL?.absoluteString == "https://cdn.example.com/images/hero.webp")
        #expect(article.heroImageProvenance == .mediaContent)
        #expect(article.sourceContents.first?.sourceElement == "content:encoded")
    }

    @Test("Atom XHTML retains nested structure, entities, and trailing text")
    func xhtmlContent() throws {
        let article = try parse("""
        <a:feed xmlns:a="http://www.w3.org/2005/Atom"><a:title>Feed</a:title><a:entry>
        <a:title>Story</a:title><a:content type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml"><p>One <b>bold</b> &amp; tail.</p><p>Two</p></div></a:content>
        </a:entry></a:feed>
        """)
        let source = try #require(article.sourceContents.first)
        #expect(source.format == .xhtml)
        #expect(source.content.contains("<p>One <b>bold</b> &amp; tail.</p><p>Two</p>"))
        #expect(article.contentHTML == source.content)
        #expect(article.title == "Story")
    }

    @Test("Unsafe URLs and declared non-image media do not become hero candidates")
    func rejectNonImages() throws {
        let article = try parse("""
        <rss xmlns:media="http://search.yahoo.com/mrss/"><channel><title>Feed</title><item><title>Story</title>
        <media:content url="https://example.com/movie.jpg" type="video/mp4"/>
        <media:thumbnail url="javascript:alert(1)"/>
        <media:thumbnail url=""/>
        <enclosure url="file:///tmp/photo.jpg" type="image/jpeg"/>
        <media:content url="https://example.com/podcast.jpg" medium="audio"/>
        </item></channel></rss>
        """)
        #expect(article.rssImages.isEmpty)
        #expect(article.heroImageURL == nil)
        #expect(article.heroImageProvenance == nil)
        #expect(article.feedItemGUID == nil)
    }

    @Test("Description-only and empty content remain distinguishable without invented quality")
    func descriptionSource() throws {
        let article = try parse("""
        <rss xmlns:content="http://purl.org/rss/1.0/modules/content/"><channel><title>Feed</title>
        <item><title>Story</title><description>Teaser only</description><content:encoded></content:encoded></item>
        </channel></rss>
        """)
        #expect(article.contentSource == .rssDescription)
        #expect(article.contentQuality == .unknown)
        #expect(article.sourceContents[0].quality == .empty)
        #expect(article.sourceContents[1].content == "Teaser only")
        #expect(article.sourceContents[1].format == .plainText)
    }
}
