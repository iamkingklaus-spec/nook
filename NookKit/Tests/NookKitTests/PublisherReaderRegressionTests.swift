import Foundation
import Testing
@testable import NookKit

private func publisherInput(_ html: String) -> BlockReaderInput {
    .init(articleID: "publisher", url: URL(string: "https://example.org/article")!, html: html, paragraphs: [], source: .extractedReaderContent)
}
private func plainResponse(_ blocks: [BlockTranslationText], omit: String? = nil, duplicate: String? = nil) throws -> String {
    var entries = blocks.flatMap(TextOnlyBlockTranslation.runs).filter { $0.id != omit }.map {
        ["blockID": $0.id, "translatedText": "译文 " + $0.text]
    }
    if let duplicate, let entry = entries.first(where: { $0["blockID"] == duplicate }) { entries.append(entry) }
    return String(decoding: try JSONSerialization.data(withJSONObject: ["translations": Array(entries.reversed())]), as: UTF8.self)
}

@Suite("Publisher reader regressions")
struct PublisherReaderRegressionTests {
    @Test func bbcBylineKeepsNameRoleBoundaries() {
        let normalized = ReaderSemanticHTML.normalize(PublisherReaderFixtures.bbc)
        #expect(normalized.contains("Kali Hays</span><br><span>Technology reporter"))
        #expect(!ReaderHTMLSignals.plain(normalized).contains("HaysTechnology"))
        let doc = BlockReaderDocument(input: publisherInput(PublisherReaderFixtures.bbc))
        let candidates = doc.texts.map(\.template).joined()
        for metadata in ["Kali Hays", "Lily Jamali", "Technology reporter", "correspondent", "September 2026", "Updated 19"] {
            #expect(!candidates.contains(metadata))
        }
        #expect(doc.document.blocks.contains { $0.sourceContent.contains("Kali Hays") })
        #expect(doc.eligibility.values.contains(.author))
        #expect(doc.eligibility.values.contains(.publicationDate))
    }

    @Test func inlineBoundariesRespectPunctuationContractionsCurrencyAndUnits() {
        let html = "<p>can<em>not</em>, James<span>’s</span> $<b>25</b>, 20<span>kg</span> and don<strong>’t</strong>!</p><div>Next<br>line</div>"
        let normalized = ReaderSemanticHTML.normalize(html)
        #expect(ReaderHTMLSignals.plain(normalized) == "cannot, James’s $25, 20kg and don’t! Next line")
        #expect(normalized.contains("Next<br>line"))
    }

    @Test func guardianParagraphsAndClasslessPromotionsAreSeparated() {
        let doc = BlockReaderDocument(input: publisherInput(PublisherReaderFixtures.guardian))
        let bodies = doc.texts.filter { $0.template.contains("Paragraph") }
        #expect(bodies.count == 3)
        let all = doc.document.blocks.map(\.sourceContent).joined()
        for noise in ["Explore more", "Prefer the Guardian", "Reuse this content", "mailto:"] { #expect(!all.contains(noise)) }
        #expect(doc.preparationReasons.contains(.relatedContent))
        #expect(!doc.texts.contains { $0.template.contains("03.02 BST") })
        #expect(!doc.texts.contains { $0.template.contains("Press Association") })
    }

    @Test func nprMetadataSponsorsAndCaptionControlsAreNotTranslationInput() throws {
        let doc = BlockReaderDocument(input: publisherInput(PublisherReaderFixtures.npr))
        let prompt = try TextOnlyBlockTranslation.prompt(doc.texts)
        for metadata in ["David Cox", "September 26", "7:31 AM", "Sponsor Message", "hide caption", "toggle caption", "Ian Cheibub"] {
            #expect(!prompt.contains(metadata))
        }
        #expect(prompt.contains("A person at a conference."))
        #expect(prompt.contains("12-fold"))
        #expect(!prompt.contains("https://"))
    }

    @Test func textOnlyInputContainsNoFormatOrURLAndReconstructsClientLinks() throws {
        let block = BlockTranslationText(blockID: "paragraph", html: "<p>Read <a href='https://example.org/original'>this</a>, <em>carefully</em>. Use <code>x()</code>.</p>")
        let prompt = try TextOnlyBlockTranslation.prompt([block])
        for secret in ["https://", "<a", "⟦", "⟬", "x()"] { #expect(!prompt.contains(secret)) }
        let result = TextOnlyBlockTranslation.decode(try plainResponse([block]), blocks: [block])
        let template = try #require(result.translations[block.blockID])
        let html = try block.restore(template)
        #expect(html.contains("href='https://example.org/original'"))
        #expect(html.contains("<em>译文 carefully</em>"))
        #expect(html.contains("<code>x()</code>"))
    }

    @Test func oneMissingOrDuplicateRunCannotDiscardOtherParents() throws {
        let blocks = [BlockTranslationText(blockID: "a", html: "A <em>complex</em> paragraph."), BlockTranslationText(blockID: "b", html: "Other paragraph.")]
        let failedID = try #require(TextOnlyBlockTranslation.runs(blocks[0]).first?.id)
        for response in [try plainResponse(blocks, omit: failedID), try plainResponse(blocks, duplicate: failedID)] {
            let result = TextOnlyBlockTranslation.decode(response, blocks: blocks)
            #expect(result.translations["a"] == nil)
            #expect(result.translations["b"] != nil)
            #expect(result.failures.first?.blockID == "a")
        }
    }

    @Test func invalidModelMarkupIsLocalAndDiagnosedByRule() throws {
        let blocks = [BlockTranslationText(blockID: "a", html: "First"), BlockTranslationText(blockID: "b", html: "Second")]
        let response = try plainResponse(blocks).replacingOccurrences(of: "译文 First", with: "<b>wrong</b>")
        let result = TextOnlyBlockTranslation.decode(response, blocks: blocks)
        #expect(result.translations.count == 1)
        #expect(result.failures.first?.rule.hasPrefix("nonTextResponse:") == true)
    }

    @Test func legacyProtectedFormatFailureSalvagesOtherBlocks() throws {
        let blocks = [BlockTranslationText(blockID: "a", html: "<em>First</em>"), BlockTranslationText(blockID: "b", html: "Second")]
        let json = #"{"translations":[{"blockID":"a","translatedText":"丢失标记"},{"blockID":"b","translatedText":"第二段"}]}"#
        #expect(throws: BlockTranslationError.markup("a")) { try BlockTranslationProtocol.validate(json, expected: blocks) }
        #expect(try BlockTranslationProtocol.salvage(json, expected: blocks) == ["b": "第二段"])
    }

    @Test func standalonePublishedUpdatedAndRoleLabelsAreMetadata() {
        for value in ["26 September 2026", "Updated 19 minutes ago", "Updated 26 September 2026", "Technology reporter", "North America Technology correspondent"] {
            #expect(TranslationEligibility.classify(value) != .prose)
        }
        #expect(TranslationEligibility.classify("The reporter updated the story 19 minutes ago.") == .prose)
    }

    @Test func captionTranslatesButCreditStaysClientOwned() {
        let image = HTMLMedia(url: URL(string: "https://example.org/image.jpg")!, title: nil,
            caption: "A scene. Photograph: André Penner/AP", posterURL: nil, aspectRatio: nil)
        let doc = BlockReaderDocument(blocks: [.image(image)], source: .extractedReaderContent, baseURL: nil)
        #expect(doc.texts.count == 1)
        #expect(doc.texts[0].template == "A scene.")
        #expect(doc.nodes.contains { if case .photoCredit = $0 { return true }; return false })
    }

    @Test func legacyDiagnosticsIdentifyExactMarkerInvariant() {
        let block = BlockTranslationText(blockID: "problem", html: "<em>First</em><strong>Second</strong>")
        #expect(block.inlineFailureRule("译文") == "missingInlineMarker:0")
        #expect(block.inlineFailureRule("⟦0⟧一⟦/0⟧⟦0⟧二⟦/0⟧") == "duplicateInlineMarker:0")
        #expect(block.inlineFailureRule("⟦0⟧⟦1⟧一⟦/0⟧⟦/1⟧") == "misnestedClosingMarker:0")
        #expect(block.inlineFailureRule(block.template) == nil)
    }

    @Test func semanticMetadataNeverCoalescesFollowingParagraphs() {
        let html = "<div class='byline'>Jane Doe</div><p>First.</p><span itemprop='publisher'>BBC</span><time datetime='2026-09-26'>Today</time><p>Second.</p><p>Third.</p>"
        let doc = BlockReaderDocument(input: publisherInput(html))
        #expect(doc.texts.count == 3)
        #expect(doc.texts.allSatisfy { !$0.template.contains("BBC") && !$0.template.contains("Jane Doe") })
    }

    @Test func allTextKindsUseClientReconstructionWithReorderedSegments() throws {
        let doc = BlockReaderDocument(blocks: [.heading(level: 2, html: "A <em>heading</em>"),
            .blockquote([.text("A <a href='/original'>quotation</a>.")]),
            .list(ordered: true, items: [[.text("One <strong>item</strong>.")], [.text("Another item.")]])],
            source: .extractedReaderContent, baseURL: nil)
        let result = TextOnlyBlockTranslation.decode(try plainResponse(doc.texts), blocks: doc.texts)
        #expect(result.failures.isEmpty)
        #expect(result.translations.count == 4)
        let restored = try doc.texts.map { try $0.restore(result.translations[$0.blockID]!) }.joined()
        #expect(restored.contains("href='/original'"))
        #expect(restored.contains("<strong>译文 item</strong>"))
    }
}

private actor PublisherTransport {
    var calls: [[String]] = []
    func request(_ blocks: [BlockTranslationText]) throws -> String {
        calls.append(blocks.map(\.blockID))
        let omitted = calls.count == 1 ? blocks.first.flatMap { TextOnlyBlockTranslation.runs($0).first?.id } : nil
        let result = TextOnlyBlockTranslation.decode(try plainResponse(blocks, omit: omitted), blocks: blocks)
        let entries = result.translations.map { ["blockID": $0.key, "translatedText": $0.value] }
        return String(decoding: try JSONSerialization.data(withJSONObject: ["translations": entries]), as: UTF8.self)
    }
}

@Suite("Publisher partial translation lifecycle") @MainActor
struct PublisherTranslationLifecycleTests {
    @Test func oneDamagedBlockOutOfTwentyPreservesNineteenAndResumesOne() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("publisher-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = publisherInput((0..<20).map { "<p>Paragraph \($0) with <em>emphasis</em>.</p>" }.joined())
        let spy = PublisherTransport()
        let transport = BlockTranslationTransport { blocks, _ in try await spy.request(blocks) }
        let first = BlockReaderTranslationController(cache: BlockTranslationCache(directory: directory), transport: transport)
        await first.load(input)
        await first.translate()
        #expect(first.translatedCount == 19 && first.totalCount == 20)
        #expect(first.message?.contains("部分翻译失败") == true)
        let reopened = BlockReaderTranslationController(cache: BlockTranslationCache(directory: directory), transport: transport)
        await reopened.load(input)
        #expect(reopened.translatedCount == 19)
        await reopened.translate()
        #expect(reopened.isComplete)
        let calls = await spy.calls
        #expect(calls.count == 3 && calls.last?.count == 1)
    }
}
