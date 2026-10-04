import Foundation
import Testing
@testable import NookKit

enum BackgroundFixture {
    static let text = "The Federal Reserve raised interest rates after reviewing inflation."
    static let uncertain = #"{"entity":"Federal Reserve","category":"Institution","definition":"美国的中央银行体系。","generalBackground":["其职责包括制定货币政策。"],"relationStatus":"insufficient","articleRelation":null,"evidenceQuote":null}"#
    static func input(long: Bool = false) throws -> BackgroundInput {
        let paragraphs = (0..<80).map { i in
            ArticleBlock(kind: .paragraph, sourceContent: i == 40 ? text : "Neighbor \(i): " + String(repeating: "context ", count: long ? 1000 : 1))
        }
        let doc = ArticleDocument(source: .rssFullContent, blocks: paragraphs)
        let article = LearningArticleContext(articleID: "a", articleURL: URL(string: "https://example.com/a")!, title: "Interest rates", publisher: "News", publishedAt: Date(timeIntervalSince1970: 1780000000))
        let selection = try #require(LearningSelection.resolve(article: article, document: doc, blockID: doc.blocks[40].id,
            renderedSource: text, range: (text as NSString).range(of: "Federal Reserve")))
        return try #require(BackgroundInput(selection: selection, document: doc))
    }
}

@Suite("On-demand background annotation")
struct BackgroundAnnotationTests {
    @Test func selectedEntityAndContextRemainBounded() throws {
        let input = try BackgroundFixture.input(long: true)
        #expect(input.selectedText == "Federal Reserve")
        #expect(input.paragraph == BackgroundFixture.text)
        #expect(input.neighbors.count == 2 && input.neighbors.allSatisfy { $0.text.count <= 450 })
        let prompt = try input.prompt()
        #expect(!prompt.contains("Neighbor 0:") && prompt.contains("Neighbor 39:") && prompt.contains("Neighbor 41:"))
        #expect(prompt.count < 5500)
        #expect(!prompt.contains("https://") && !prompt.contains("canonicalURL"))
        #expect(input.publicationDate != nil)
    }
    @Test func uncertaintyIsValid() throws {
        let value = try BackgroundProtocol.decode(BackgroundFixture.uncertain, input: BackgroundFixture.input())
        #expect(value.relationStatus == .insufficient && value.articleRelation == nil)
    }
    @Test func relationshipRequiresExactContextEvidence() throws {
        let value = BackgroundAnnotation(entity: "Federal Reserve", category: "Institution", definition: "美国央行体系。", generalBackground: [], relationStatus: .supported, articleRelation: "本文提到加息。", evidenceQuote: BackgroundFixture.text)
        let response = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        #expect(try BackgroundProtocol.decode(response, input: BackgroundFixture.input()).relationStatus == .supported)
        #expect(throws: StoryContextError.self) {
            try BackgroundProtocol.decode(response.replacingOccurrences(of: BackgroundFixture.text, with: "An invented quote about interest rates"), input: BackgroundFixture.input())
        }
    }
    @Test func malformedResponseFailsSafely() throws {
        #expect(throws: StoryContextError.self) { try BackgroundProtocol.decode("not json", input: BackgroundFixture.input()) }
    }
    @Test func modelAndContextInvalidateCache() throws {
        let input = try BackgroundFixture.input()
        #expect(try BackgroundProtocol.key(input, model: .flash) != BackgroundProtocol.key(input, model: .flashLite))
        #expect(try BackgroundProtocol.key(input, model: .flashLite) != BackgroundProtocol.key(BackgroundFixture.input(long: true), model: .flashLite))
    }
    @Test @MainActor func cacheSurvivesControllerReload() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = try BackgroundFixture.input()
        let first = BackgroundController(cache: StoryContextCache(directory: directory), transport: ContextTransport { _,_,_,_ in BackgroundFixture.uncertain })
        await first.load(input)
        #expect(first.result != nil)
        let second = BackgroundController(cache: StoryContextCache(directory: directory), transport: ContextTransport { _,_,_,_ in Issue.record("Unexpected network"); return "" })
        await second.load(input)
        #expect(second.result != nil && second.cacheHit)
    }
    @Test func mismatchedDocumentIsRejected() throws {
        let doc = ArticleDocument(source: .rssFullContent, blocks: [.init(kind: .paragraph, sourceContent: BackgroundFixture.text)])
        let article = LearningArticleContext(articleID: "a", articleURL: URL(string: "https://example.com/a")!, title: "Rates", publisher: "News")
        let selection = try #require(LearningSelection.resolve(article: article, document: doc, blockID: doc.blocks[0].id,
            renderedSource: BackgroundFixture.text, range: NSRange(location: 4, length: 15)))
        let changed = ArticleDocument(source: .rssFullContent, blocks: [.init(kind: .paragraph, sourceContent: "Changed body")])
        #expect(BackgroundInput(selection: selection, document: changed) == nil)
    }
}
