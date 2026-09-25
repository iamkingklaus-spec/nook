import Foundation
import Testing
@testable import NookKit

private func cleaningInput(_ html: String) -> BlockReaderInput {
    .init(articleID: "cleaning", url: URL(string: "https://example.org/story")!, html: html,
          paragraphs: [], source: .extractedReaderContent)
}

private func prose(_ doc: BlockReaderDocument) -> [String] {
    doc.texts.map { ReaderHTMLSignals.plain((try? $0.restore($0.template)) ?? "") }
}

@Suite("Conservative reader body preparation")
struct ReaderBlockPreparationTests {
    @Test func explicitAdvertisementRemoved() {
        let doc = BlockReaderDocument(input: cleaningInput("<p>News.</p><div class='ad-container'><p>Buy now</p></div><p>Advertisement</p>"))
        #expect(prose(doc) == ["News."])
        #expect(doc.preparationReasons == [.semanticAdvertisement, .semanticAdvertisement])
    }

    @Test func newsletterSignupRemoved() {
        let doc = BlockReaderDocument(input: cleaningInput("<p>News.</p><aside class='newsletter-signup'><h2>Daily updates</h2><p>Enter email</p></aside>"))
        #expect(prose(doc) == ["News."])
        #expect(doc.preparationReasons == [.newsletterPromotion])
    }

    @Test func relatedStoriesModuleRemoved() {
        let doc = BlockReaderDocument(input: cleaningInput("<p>News.</p><section id='related-stories'><h2>Related stories</h2><ul><li><a href='/other'>Another story</a></li></ul></section>"))
        #expect(prose(doc) == ["News."])
        #expect(doc.preparationReasons == [.relatedContent])
    }

    @Test func navigationFooterAndPrivacyUseExplicitSignals() {
        let html = "<nav><a href='/'>Home</a></nav><p>News.</p><footer role='contentinfo'>Site links</footer><div class='cookie-consent'>Cookies</div>"
        let result = ArticleNoiseFilter.filter(html)
        #expect(result.html == "<p>News.</p>")
        #expect(result.reasons == [.navigation, .footer, .privacyPrompt])
    }

    @Test func ordinaryShareSubscribeAndRelatedWordsSurvive() {
        let values = ["They share responsibility for the decision.", "I subscribe to that view.", "The findings are related to climate."]
        let doc = BlockReaderDocument(input: cleaningInput(values.map { "<p>\($0)</p>" }.joined()))
        #expect(prose(doc) == values)
        #expect(doc.preparationReasons.isEmpty)
    }

    @Test func uncertainClassAndUnclosedContainerSurvive() {
        for html in ["<aside class='related'>Scientific evidence</aside>", "<div class='ad-container'><p>Uncertain article</p>"] {
            #expect(ArticleNoiseFilter.filter(html).html == html)
        }
    }

    @Test func quotedAndCodePromotionWordsSurvive() {
        let html = "<blockquote><p>Sign in</p></blockquote><pre><code>Advertisement</code></pre><p><code>Advertisement</code></p>"
        #expect(ArticleNoiseFilter.filter(html).html == html)
        let doc = BlockReaderDocument(input: cleaningInput(html))
        #expect(prose(doc) == ["Sign in"])
        #expect(doc.preparationReasons.isEmpty)
    }

    @Test func photoCreditKeptButNotTranslated() {
        let doc = BlockReaderDocument(input: cleaningInput("<p>News.</p><p>Photograph: André Penner/AP</p>"))
        #expect(prose(doc) == ["News."])
        #expect(doc.document.blocks.contains { $0.sourceContent.contains("André Penner/AP") })
        #expect(doc.eligibility.values.contains(.photoCredit))
    }

    @Test func semanticAuthorPublisherAndPublishedTimeKept() {
        let html = "<div><span class='byline'>Jane Doe</span><p>News.</p><span itemprop='publisher'>BBC</span><time itemprop='datePublished' datetime='2026-09-25'>September 25</time></div>"
        let doc = BlockReaderDocument(input: cleaningInput(html))
        #expect(prose(doc) == ["News."])
        #expect(doc.eligibility.values.contains(.author))
        #expect(doc.eligibility.values.contains(.publisher))
        #expect(doc.eligibility.values.contains(.publicationDate))
        #expect(doc.document.blocks.contains { $0.sourceContent.contains("Jane Doe") })
    }

    @Test func captionTranslatedOnlyOnce() {
        let media = HTMLMedia(url: URL(string: "https://example.org/image.png")!, title: nil,
                              caption: "A city at dawn", posterURL: nil, aspectRatio: nil)
        let doc = BlockReaderDocument(blocks: [.image(media), .text("<p>A city at dawn</p>"), .text("News.")],
            source: .rssFullContent, baseURL: nil)
        #expect(prose(doc) == ["A city at dawn", "News."])
        #expect(doc.preparationReasons == [.duplicateCaption])
        guard case .unchanged(.image(let image)) = doc.nodes.first else { Issue.record("Image missing"); return }
        #expect(image.caption == nil)
    }

    @Test func inlineLinkVisibleTextEligibleAndTargetUnchanged() throws {
        let doc = BlockReaderDocument(input: cleaningInput("<p>Read <a href='https://example.org/a?q=two  words'>the report</a>.</p>"))
        let text = try #require(doc.texts.first)
        #expect(!text.template.contains("https://"))
        #expect(text.template.contains("the report"))
        #expect(try text.restore("译文 " + text.template).contains("href='https://example.org/a?q=two  words'"))
    }

    @Test func whitespaceAndAdjacentDuplicatesNormalized() {
        let doc = BlockReaderDocument(blocks: [.text(" \n\t"), .text("<p>&nbsp;</p>"), .text("One  sentence."),
            .text("One sentence."), .text("Two\n\n sentences.")], source: .rssFullContent, baseURL: nil)
        #expect(prose(doc) == ["One sentence.", "Two sentences."])
        #expect(doc.preparationReasons == [.empty, .empty, .duplicate])
    }

    @Test func independentParagraphsNeverMerge() {
        let doc = BlockReaderDocument(input: cleaningInput("<p>First.</p><p>Second.</p>"))
        #expect(prose(doc) == ["First.", "Second."])
        #expect(doc.document.blocks.count == 2)
    }

    @Test func quoteListAndHeadingStructurePreserved() {
        let doc = BlockReaderDocument(blocks: [.heading(level: 2, html: "Heading"), .blockquote([.text("Quote"), .text("Quote")]),
            .list(ordered: true, items: [[.text("Item one")], [.text("Item two")]])], source: .rssFullContent, baseURL: nil)
        guard case .text(_, _, let level) = doc.nodes[0], case .quote(let quote) = doc.nodes[1],
              case .list(let ordered, let items) = doc.nodes[2] else { Issue.record("Lost topology"); return }
        #expect(level == 2 && quote.count == 2 && ordered && items.count == 2)
    }

    @Test func normalizedIdentityIsDeterministic() {
        let first = BlockReaderDocument(input: cleaningInput("<p>The  news.</p><p>Next.</p>"))
        let second = BlockReaderDocument(input: cleaningInput("<p>The news.</p><p>Next.</p>"))
        #expect(first.document == second.document)
        #expect(first.texts.map(\.blockID) == second.texts.map(\.blockID))
        #expect(first.document.documentHash == BlockReaderDocument(input: cleaningInput("<p>The  news.</p><p>Next.</p>")).document.documentHash)
    }

    @Test func changedBodyInvalidatesIdentity() {
        let first = BlockReaderDocument(input: cleaningInput("<p>First.</p>"))
        let second = BlockReaderDocument(input: cleaningInput("<p>Changed.</p>"))
        #expect(first.document.documentHash != second.document.documentHash)
    }

    @Test func shortSemanticProseEligibleButMetadataNotSent() {
        let doc = BlockReaderDocument(blocks: [.text("Why?"), .text("No."), .text("2026-09-25"), .text("1,234"),
            .text("https://example.org/"), .text("By Jane Doe"), .text("September 25, 2026")], source: .rssFullContent, baseURL: nil)
        #expect(prose(doc) == ["Why?", "No."])
        #expect(doc.nodes.count == 7)
    }

    @Test func rawInputAndOriginalURLNeverMutated() {
        let input = cleaningInput("<div class='advertisement'>Ad</div><p>News.</p>")
        let html = input.html, url = input.url
        let doc = BlockReaderDocument(input: input)
        #expect(prose(doc) == ["News."])
        #expect(input.html == html && input.url == url)
    }

    @Test func inlineAuthorWithinSentenceDoesNotSplitParagraph() {
        let doc = BlockReaderDocument(input: cleaningInput("<p>The interview with <a rel='author' href='/jane'>Jane Doe</a> took place today.</p>"))
        #expect(doc.texts.count == 1)
        #expect(prose(doc) == ["The interview with Jane Doe took place today."])
    }

    @Test func uiPhraseInsideARealSentenceSurvives() {
        let html = "<p>The button labelled <span>Sign in</span> was removed.</p>"
        #expect(ArticleNoiseFilter.filter(html).html == html)
        #expect(prose(BlockReaderDocument(input: cleaningInput(html))) == ["The button labelled Sign in was removed."])
        #expect(ArticleNoiseFilter.filter("<div><h1>Advertisement</h1></div>").reasons.isEmpty)
    }
}
