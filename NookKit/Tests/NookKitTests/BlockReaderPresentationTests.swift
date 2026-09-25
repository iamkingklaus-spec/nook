import Foundation
import Testing
@testable import NookKit

private let wrappedParagraphs = "<div><p>A</p><p>B</p><p>C</p></div>"

private func readerInput(_ html: String) -> BlockReaderInput {
    .init(articleID: "presentation", url: URL(string: "https://example.com/story")!,
          html: html, paragraphs: [], source: .rssFullContent)
}

private func translated(_ value: String) -> String {
    ["A", "B", "C"].reduce(value) { $0.replacingOccurrences(of: $1, with: $1 + "-zh") }
}

private func presentation(_ document: BlockReaderDocument, omitted: Set<String> = []) throws -> [BlockReaderPresentationNode] {
    let templates = Dictionary(uniqueKeysWithValues: document.texts.filter { !omitted.contains($0.blockID) }
        .map { ($0.blockID, translated($0.template)) })
    let html = try Dictionary(uniqueKeysWithValues: document.texts.compactMap { text -> (String, String)? in
        guard let value = templates[text.blockID] else { return nil }
        return (text.blockID, try text.restore(value))
    })
    return BlockReaderPresentation.nodes(document.nodes, translations: html, templates: templates)
}

/// Flatten the actual presentation tree consumed by the SwiftUI renderer.
private func output(_ nodes: [BlockReaderPresentationNode], mode: BlockReaderMode = .bilingual) -> [String] {
    nodes.flatMap { node -> [String] in
        switch node {
        case .group(let group): return group.texts(in: mode).map {
            HTMLContentParser.decodeEntities($0.html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
        }
        case .quote(let children): return output(children, mode: mode)
        case .list(_, let items): return items.flatMap { output($0, mode: mode) }
        case .unchanged(.image): return ["image"]
        case .unchanged(.codeBlock): return ["code"]
        case .unchanged(.table): return ["table"]
        case .unchanged: return ["unchanged"]
        }
    }
}

@Suite("Block reader presentation order")
struct BlockReaderPresentationTests {
    @Test func paragraphsAlternateImmediately() throws {
        let document = BlockReaderDocument(input: readerInput("<p>A</p><p>B</p><p>C</p>"))
        #expect(document.texts.count == 3)
        #expect(try output(presentation(document)) == ["A", "A-zh", "B", "B-zh", "C", "C-zh"])
    }

    @Test func compositeLegacyBlockAlternatesWithoutChangingIdentity() throws {
        let document = BlockReaderDocument(input: readerInput(wrappedParagraphs))
        // This is the regression: the existing parser retains one composite block.
        #expect(document.texts.count == 1)
        let before = document.document.documentHash
        let nodes = try presentation(document)
        #expect(output(nodes) == ["A", "A-zh", "B", "B-zh", "C", "C-zh"])
        let groups = nodes.compactMap { node -> BlockReaderPresentationNode.Group? in
            if case .group(let group) = node { return group }; return nil
        }
        #expect(Set(groups.map(\.id)).count == 3)
        #expect(groups.allSatisfy { $0.blockID == document.texts[0].blockID })
        #expect(document.document.documentHash == before)
        #expect(document.texts[0].template == BlockReaderDocument(input: readerInput(wrappedParagraphs)).texts[0].template)
    }

    @Test func reorderedResponseUsesSourceBlockOrder() throws {
        let document = BlockReaderDocument(input: readerInput("<p>A</p><p>B</p><p>C</p>"))
        let json = String(decoding: try JSONSerialization.data(withJSONObject: ["translations": document.texts.reversed().map {
            ["blockID": $0.blockID, "translatedText": translated($0.template)]
        }]), as: UTF8.self)
        let templates = try BlockTranslationProtocol.validate(json, expected: document.texts)
        let html = try Dictionary(uniqueKeysWithValues: document.texts.map { ($0.blockID, try $0.restore(templates[$0.blockID]!)) })
        #expect(output(BlockReaderPresentation.nodes(document.nodes, translations: html, templates: templates)) ==
            ["A", "A-zh", "B", "B-zh", "C", "C-zh"])
    }

    @Test func reorderedParagraphMarkersStillPairByIdentity() throws {
        let document = BlockReaderDocument(input: readerInput(wrappedParagraphs))
        let text = try #require(document.texts.first)
        let value = "⟦0⟧⟦3⟧C-zh⟦/3⟧⟦1⟧A-zh⟦/1⟧⟦2⟧B-zh⟦/2⟧⟦/0⟧"
        let html = try text.restore(value)
        #expect(output(BlockReaderPresentation.nodes(document.nodes, translations: [text.blockID: html],
            templates: [text.blockID: value])) == ["A", "A-zh", "B", "B-zh", "C", "C-zh"])
    }

    @Test func missingTranslationDoesNotMoveOtherPairs() throws {
        let document = BlockReaderDocument(input: readerInput("<p>A</p><p>B</p><p>C</p>"))
        let nodes = try presentation(document, omitted: [document.texts[1].blockID])
        #expect(output(nodes) == ["A", "A-zh", "B", "C", "C-zh"])
        #expect(output(nodes, mode: .chinese) == ["A-zh", "B", "C-zh"])
    }

    @Test func emptyCompositeParagraphTranslationFallsBackToSource() throws {
        let document = BlockReaderDocument(input: readerInput(wrappedParagraphs))
        let text = try #require(document.texts.first)
        let value = translated(text.template).replacingOccurrences(of: "B-zh", with: " ")
        #expect(output(BlockReaderPresentation.nodes(document.nodes, translations: [text.blockID: try text.restore(value)],
            templates: [text.blockID: value])) == ["A", "A-zh", "B", "C", "C-zh"])
    }

    @Test func headingQuoteAndEachListItemKeepPairsAndStructure() throws {
        let document = BlockReaderDocument(blocks: [.heading(level: 2, html: "A"), .blockquote([.text("B")]),
            .list(ordered: true, items: [[.text("A")], [.text("C")]])], source: .rssFullContent, baseURL: nil)
        let nodes = try presentation(document)
        #expect(output(nodes) == ["A", "A-zh", "B", "B-zh", "A", "A-zh", "C", "C-zh"])
        guard case .group(let heading) = nodes[0], case .quote = nodes[1],
              case .list(let ordered, let items) = nodes[2] else { Issue.record("Lost structure"); return }
        #expect(heading.heading == 2)
        #expect(ordered && items.count == 2)
        #expect(output(items[1]) == ["C", "C-zh"])
    }

    @Test func imageOnceCaptionPairedCodeAndTableUnchanged() throws {
        let image = HTMLMedia(url: URL(string: "https://example.com/image.png")!, title: nil,
                              caption: "A", posterURL: nil, aspectRatio: nil)
        let table = HTMLTable(rows: [.init(cells: [.init(html: "Cell", isHeader: false)])])
        let document = BlockReaderDocument(blocks: [.image(image), .codeBlock(code: "foo()", language: "swift"),
            .table(table)], source: .rssFullContent, baseURL: nil)
        let nodes = try presentation(document)
        #expect(output(nodes) == ["image", "A", "A-zh", "code", "table"])
        #expect(output(nodes, mode: .english) == ["image", "A", "code", "table"])
        #expect(output(nodes, mode: .chinese) == ["image", "A-zh", "code", "table"])
        guard case .unchanged(.image(let picture)) = nodes[0],
              case .unchanged(.codeBlock(let code, _)) = nodes[2],
              case .unchanged(.table(let renderedTable)) = nodes[3] else { Issue.record("Lost media"); return }
        #expect(picture.caption == nil && picture.url == image.url)
        #expect(code == "foo()")
        #expect(renderedTable.rows[0].cells[0].html == "Cell")
    }

    @Test func inlineLinksAndCodeSurviveCompositePresentation() throws {
        let document = BlockReaderDocument(input: readerInput("<section><p>A <a href='/original'>link</a></p><p>B <code>foo()</code></p></section>"))
        let nodes = try presentation(document)
        #expect(output(nodes) == ["A link", "A-zh link", "B foo()", "B-zh foo()"])
        guard case .group(let first) = nodes[0], case .group(let second) = nodes[1] else { return }
        #expect(first.translatedHTML?.contains("href='/original'") == true)
        #expect(second.translatedHTML?.contains("<code>foo()</code>") == true)
    }

    @Test func looseContentAndReservedAttributesUseLosslessFallback() throws {
        for html in ["<div>Introduction<p>A</p><p>B</p></div>",
                     "<div data-nook-presentation-id='9'><p>A</p><p>B</p></div>"] {
            let document = BlockReaderDocument(blocks: [.text(html)], source: .rssFullContent, baseURL: nil)
            let nodes = try presentation(document)
            #expect(nodes.count == 1)
            guard case .group(let group) = nodes[0] else { Issue.record("Missing source"); continue }
            #expect(group.sourceHTML == html)
            #expect(group.translatedHTML != nil)
        }
    }

    @Test func compositeWithoutTranslationRemainsSourceOrdered() throws {
        let document = BlockReaderDocument(input: readerInput(wrappedParagraphs))
        let nodes = try presentation(document, omitted: Set(document.texts.map(\.blockID)))
        for mode in BlockReaderMode.allCases { #expect(output(nodes, mode: mode) == ["A", "B", "C"]) }
    }
}

private actor PresentationRequests {
    var count = 0
    func request(_ blocks: [BlockTranslationText]) throws -> String {
        count += 1
        return String(decoding: try JSONSerialization.data(withJSONObject: ["translations": blocks.map {
            ["blockID": $0.blockID, "translatedText": translated($0.template)]
        }]), as: UTF8.self)
    }
}

@Suite("Presentation cache and modes") @MainActor
struct BlockReaderPresentationLifecycleTests {
    @Test func cachedCompositeAndAllModesDoNotRequestAgain() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("presentation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let spy = PresentationRequests()
        let transport = BlockTranslationTransport { blocks, _ in try await spy.request(blocks) }
        let first = BlockReaderTranslationController(cache: BlockTranslationCache(directory: directory), transport: transport)
        let input = readerInput(wrappedParagraphs)
        await first.load(input)
        await first.translate()
        #expect(await spy.count == 1)
        let reopened = BlockReaderTranslationController(cache: BlockTranslationCache(directory: directory), transport: transport)
        await reopened.load(input)
        #expect(reopened.isComplete)
        for controller in [first, reopened] {
            let document = try #require(controller.prepared)
            for mode: BlockReaderMode in [.english, .bilingual, .chinese, .bilingual] {
                controller.mode = mode
                let nodes = BlockReaderPresentation.nodes(document.nodes, translations: controller.translatedHTML,
                                                          templates: controller.presentationTranslations)
                let expected = mode == .english ? ["A", "B", "C"] : mode == .chinese ? ["A-zh", "B-zh", "C-zh"] :
                    ["A", "A-zh", "B", "B-zh", "C", "C-zh"]
                #expect(output(nodes, mode: mode) == expected)
            }
        }
        #expect(await spy.count == 1)
    }
}
