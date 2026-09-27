import Foundation
import Testing
@testable import NookKit

// Offline structural fixture matching the reported live-blog modules. It is
// deliberately not presented as a captured copy of the unavailable source DOM.
private let guardianLiveFixture = """
<article><div class="live-entry-meta"><span>From</span><span>1h ago</span><time>09.55 BST</time></div>
<p>Ordinary news paragraph.</p>
<figure><img src="https://example.org/photo.jpg"><figcaption>A speaker at the conference. Photograph: Phil Noble/Reuters</figcaption></figure>
<div><a href="https://www.theguardian.com/politics/live/2026/sep/27/another-blog"><div>Northern Ireland live: another report</div><span>Read more</span></a></div>
<div><span><em>Q: What will change?</em></span><p><em>Q: What will change?</em></p></div>
<p>The answer explains the proposal.</p></article>
"""

private func liveDocument(_ html: String, url: String = "https://www.theguardian.com/politics/live/2026/sep/27/main") -> BlockReaderDocument {
    BlockReaderDocument(input: .init(articleID: "live", url: URL(string: url)!, html: html, paragraphs: [], source: .extractedReaderContent))
}
private func liveProse(_ doc: BlockReaderDocument) -> [String] {
    doc.texts.map { ReaderHTMLSignals.plain((try? $0.restore($0.template)) ?? "") }
}

@Suite("Live reader auxiliary modules")
struct LiveReaderCleanupTests {
    @Test func entireRelatedCardAndMetadataStayOutOfDocumentAndPrompt() throws {
        let doc = liveDocument(guardianLiveFixture)
        let content = doc.document.blocks.map(\.sourceContent).joined()
        let prompt = try TextOnlyBlockTranslation.prompt(doc.texts)
        for value in ["Northern Ireland", "Read more", "Photograph", "Phil Noble", "From", "1h ago", "09.55", "BST"] {
            #expect(!content.contains(value))
            #expect(!prompt.contains(value))
        }
        #expect(liveProse(doc) == ["Ordinary news paragraph.", "A speaker at the conference.", "Q: What will change?", "The answer explains the proposal."])
        #expect(doc.preparationReasons.contains(.relatedContent))
        #expect(doc.preparationReasons.contains(.liveEntryMetadata))
    }

    @Test func photoCreditIsImageMetadataAndNotAnArticleBlock() throws {
        let doc = liveDocument(guardianLiveFixture)
        let credits = doc.nodes.compactMap { node -> ReaderPhotoCredit? in
            if case .photoCredit(let credit) = node { return credit }; return nil
        }
        let credit = try #require(credits.first)
        #expect(credits.count == 1)
        #expect(credit.text == "Photograph: Phil Noble/Reuters")
        #expect(credit.imageURL?.absoluteString == "https://example.org/photo.jpg")
        #expect(doc.document.blocks.filter { $0.kind == .image }.count == 1)
    }

    @Test func standaloneCreditIsSmallMetadataWithOptionalImageAssociation() {
        let doc = liveDocument("<img src='https://example.org/a.jpg'><p>Photograph: A Person/AP</p><p>Body.</p><p>Photograph: Someone Else/AP</p>")
        let credits = doc.nodes.compactMap { node -> ReaderPhotoCredit? in if case .photoCredit(let credit) = node { return credit }; return nil }
        #expect(credits.count == 2)
        #expect(credits.first?.imageURL?.absoluteString == "https://example.org/a.jpg")
        #expect(credits.last?.imageURL == nil)
        #expect(liveProse(doc) == ["Body."])
    }

    @Test func creditChangesDoNotPolluteDocumentOrCaptionIdentity() {
        let first = liveDocument("<figure><img src='/a.jpg'><figcaption>A caption. Photograph: Person One/AP</figcaption></figure>")
        let second = liveDocument("<figure><img src='/a.jpg'><figcaption>A caption. Photograph: Person Two/Reuters</figcaption></figure>")
        #expect(first.document == second.document)
        #expect(first.texts.map(\.blockID) == second.texts.map(\.blockID))
    }

    @Test func classlessCardWithSiblingTitleAndCTAIsRemovedInsideArticle() {
        let html = "<p>Before.</p><p><a href='/politics/another'>Related report</a></p><p><a href='/politics/another'>Read more</a></p><p>After.</p>"
        #expect(liveProse(liveDocument(html)) == ["Before.", "After."])
    }

    @Test func semanticCardsWorkOutsideGuardian() {
        let html = "<p>Before.</p><aside><a href='/related'><h3>Another report</h3><span>Read more</span></a></aside><p>After.</p>"
        #expect(liveProse(liveDocument(html, url: "https://example.org/story")) == ["Before.", "After."])
    }

    @Test func explicitRelatedComponentRemovesUnlinkedTitleToo() {
        let html = "<p>Before.</p><aside data-component='rich-link'><h3>Related article title</h3><a href='/related'>Read more</a></aside><p>After.</p>"
        #expect(liveProse(liveDocument(html, url: "https://example.org/story")) == ["Before.", "After."])
    }

    @Test func siblingLinksInOneParagraphAreRemovedAsOneCard() {
        let html = "<p>Before.</p><p><a href='/related'>A related report</a><a href='/related'>Read more</a></p><p>After.</p>"
        #expect(liveProse(liveDocument(html)) == ["Before.", "After."])
    }

    @Test func classlessTimeClusterIsHiddenBeforeSpanFlattening() {
        let html = "<div><span>From</span><span>1h ago</span><a href='#block-1'>09.55 BST</a></div><p>Body.</p>"
        #expect(liveProse(liveDocument(html)) == ["Body."])
    }

    @Test func separateLiveTimeBlocksUseAdjacentEvidence() {
        let html = "<p>From</p><p>1h ago</p><p><a href='#block-1'>09.55 BST</a></p><p>Body.</p>"
        #expect(liveProse(liveDocument(html)) == ["Body."])
    }

    @Test func explicitLiveMetadataWorksForOtherPublishers() {
        let html = "<div class='live-entry-metadata'><span>From Jane Doe</span><time>09.55 BST</time></div><p>Body.</p>"
        #expect(liveProse(liveDocument(html, url: "https://example.org/live")) == ["Body."])
    }

    @Test func ordinaryWordsAndIsolatedFromAreNeverBlacklisted() {
        let html = "<p>From</p><p>We read more from the photograph and share related evidence.</p><p>The meeting began at 09.55 BST, one hour ago.</p>"
        #expect(liveProse(liveDocument(html)).count == 3)
        #expect(liveProse(liveDocument("<p>We can <a href='/guide'><span>Read more</span></a> in the guide.</p>")).count == 1)
    }

    @Test func sourceSpecificTimesAreNotRemovedFromOrdinaryArticles() {
        let doc = liveDocument("<p>From</p><p>1h ago</p><p>09.55 BST</p>", url: "https://example.org/article")
        #expect(liveProse(doc).count == 3)
    }

    @Test func exactAdjacentQADuplicateUsesUnicodeAndWhitespaceOnly() {
        let doc = liveDocument("<div><span>Q: Café   policy?</span><p>Q: Café policy?</p></div><p>Answer.</p>")
        #expect(liveProse(doc) == ["Q: Café policy?", "Answer."])
        #expect(doc.preparationReasons.contains(.duplicate))
    }

    @Test func similarQuestionsDifferentAnswersAndNonAdjacentRepeatsSurvive() {
        let values = ["Q: Will it change?", "Q: Will it change!", "Answer.", "Q: Will it change?"]
        #expect(liveProse(liveDocument(values.map { "<p>\($0)</p>" }.joined())) == values)
    }

    @Test func exactTextWithDifferentLinkTargetsIsNotDeduplicated() {
        #expect(liveDocument("<p><a href='/one'>Question?</a></p><p><a href='/two'>Question?</a></p>").texts.count == 2)
    }

    @Test func semanticHeadingWinsOverDuplicateWrapperParagraph() {
        let doc = liveDocument("<p><span>Q: Policy?</span></p><h3>Q: Policy?</h3><p>Answer.</p>")
        #expect(liveProse(doc) == ["Q: Policy?", "Answer."])
        #expect(doc.document.blocks.contains { $0.kind == .heading })
    }

    @Test func oldRemovedTranslationsCannotRenderAndBodyCacheIdentityStaysStable() throws {
        let dirty = liveDocument("<p>Body.</p><div><a href='/related'><h3>Another report</h3><span>Read more</span></a></div>")
        let clean = liveDocument("<p>Body.</p>")
        #expect(dirty.document == clean.document)
        let block = try #require(dirty.texts.first)
        let template = block.template.replacingOccurrences(of: "Body.", with: "正文。")
        let nodes = BlockReaderPresentation.nodes(dirty.nodes, translations: [block.blockID: try block.restore(template), "removed": "阅读更多"], templates: [block.blockID: template])
        guard case .group(let group) = nodes.first else { Issue.record("Missing body"); return }
        #expect(nodes.count == 1)
        #expect(group.texts(in: .bilingual).map { ReaderHTMLSignals.plain($0.html) } == ["Body.", "正文。"])
    }

    @Test func unchangedCleanIdentityStillLoadsExistingCache() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("live-cache-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = BlockReaderInput(articleID: "live", url: URL(string: "https://www.theguardian.com/politics/live/2026/sep/27/main")!,
            html: nil, paragraphs: [], source: .extractedReaderContent)
        let clean = liveDocument("<p>Body.</p>")
        let dirty = liveDocument("<div class='live-entry-meta'>From 1h ago 09.55 BST</div><p>Body.</p>")
        let cleanKey = BlockTranslationCacheKey(input: input, document: clean.document, model: .flashLite)
        let dirtyKey = BlockTranslationCacheKey(input: input, document: dirty.document, model: .flashLite)
        let text = try #require(clean.texts.first)
        let values = [text.blockID: text.template.replacingOccurrences(of: "Body.", with: "正文。")]
        let cache = BlockTranslationCache(directory: directory)
        try await cache.store(values, key: cleanKey)
        #expect(cleanKey == dirtyKey)
        #expect(await cache.load(dirtyKey, texts: dirty.texts) == values)
    }
}
