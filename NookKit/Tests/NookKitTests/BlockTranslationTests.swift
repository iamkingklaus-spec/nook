import Foundation
import Testing
@testable import NookKit

private func response(_ entries: [(String, String)]) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: ["translations": entries.map {
        ["blockID": $0.0, "translatedText": $0.1]
    }]), as: UTF8.self)
}

private func input(_ paragraphs: [String] = ["First paragraph", "Second paragraph"], html: String? = nil,
                   url: String = "https://example.com/article") -> BlockReaderInput {
    BlockReaderInput(articleID: "article", url: URL(string: url)!, html: html,
                     paragraphs: paragraphs, source: .rssFullContent)
}

private func temporaryCache() -> (BlockTranslationCache, URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("block-tests-\(UUID())")
    return (BlockTranslationCache(directory: directory), directory)
}

private actor TranslationSpy {
    var calls: [[String]] = []
    var failCall: Int?
    init(failCall: Int? = nil) { self.failCall = failCall }
    func request(_ blocks: [BlockTranslationText]) throws -> String {
        calls.append(blocks.map(\.blockID))
        if calls.count == failCall { throw BlockTranslationError.malformed }
        return try response(blocks.reversed().map { ($0.blockID, "译文 " + $0.template) })
    }
    var transport: BlockTranslationTransport {
        BlockTranslationTransport { blocks, _ in try await self.request(blocks) }
    }
}

@Suite("Structured block translation")
struct BlockTranslationTests {
    @Test func stableIdentityAfterInsertion() {
        let before = BlockReaderDocument(input: input())
        let after = BlockReaderDocument(input: input(["Inserted", "First paragraph", "Second paragraph"]))
        #expect(before.texts.map(\.blockID) == Array(after.texts.dropFirst()).map(\.blockID))
        #expect(before.document.documentHash != after.document.documentHash)
        #expect(before.document.blocks.map(\.id) == before.texts.map(\.blockID))
    }

    @Test func nonAdjacentRepeatedParagraphsHaveDistinctStableIDs() {
        let doc = BlockReaderDocument(input: input(["Same", "Other", "Same", "Last", "Same"]))
        #expect(Set(doc.texts.map(\.blockID)).count == 5)
        #expect(doc.texts[0].blockID.hasSuffix(":0"))
        #expect(doc.texts[2].blockID.hasSuffix(":1"))
        #expect(doc.texts[4].blockID.hasSuffix(":2"))
    }

    @Test func reorderedResponseUsesIDs() throws {
        let blocks = BlockReaderDocument(input: input()).texts
        let result = try BlockTranslationProtocol.validate(response([(blocks[1].blockID, "二"), (blocks[0].blockID, "一")]), expected: blocks)
        #expect(result[blocks[0].blockID] == "一")
        #expect(result[blocks[1].blockID] == "二")
    }

    @Test func missingIDRejectsWholeBatch() throws {
        let blocks = BlockReaderDocument(input: input()).texts
        let json = try response([(blocks[0].blockID, "一")])
        #expect(throws: BlockTranslationError.missing) { try BlockTranslationProtocol.validate(json, expected: blocks) }
    }

    @Test func duplicateIDRejectsWholeBatch() throws {
        let blocks = BlockReaderDocument(input: input()).texts
        let json = try response([(blocks[0].blockID, "一"), (blocks[0].blockID, "重复")])
        #expect(throws: BlockTranslationError.duplicate(blocks[0].blockID)) {
            try BlockTranslationProtocol.validate(json, expected: blocks)
        }
    }

    @Test func unexpectedIDRejectsWholeBatch() throws {
        let blocks = BlockReaderDocument(input: input()).texts
        let json = try response([(blocks[0].blockID, "一"), ("invented", "二")])
        #expect(throws: BlockTranslationError.unexpected("invented")) { try BlockTranslationProtocol.validate(json, expected: blocks) }
    }

    @Test func emptyTranslationRejected() throws {
        let blocks = BlockReaderDocument(input: input(["First"])).texts
        let json = try response([(blocks[0].blockID, " \n\t")])
        #expect(throws: BlockTranslationError.empty(blocks[0].blockID)) { try BlockTranslationProtocol.validate(json, expected: blocks) }
    }

    @Test func malformedResponseRejected() {
        let blocks = BlockReaderDocument(input: input()).texts
        for value in ["[]", "```json\n{}\n```", "{\"translations\":null}", "{\"translations\":[],\"extra\":1}"] {
            #expect(throws: BlockTranslationError.malformed) { try BlockTranslationProtocol.validate(value, expected: blocks) }
        }
    }

    @Test func markersWithoutTranslatedProseAreEmpty() {
        let text = BlockTranslationText(blockID: "b", html: "<a href='/x'>English</a>")
        #expect(throws: BlockTranslationError.empty("b")) { try text.restore("⟦0⟧⟦/0⟧") }
    }

    @Test func linkURLsAndInlineCodeNeverReachModel() throws {
        let html = "Read <a href=\"https://example.com/x?a=1&amp;b=2\">this</a> and <code>let key = 42</code> at https://example.org/path"
        let text = BlockTranslationText(blockID: "b", html: html)
        #expect(!text.template.contains("https://"))
        #expect(!text.template.contains("let key"))
        let restored = try text.restore("中文 " + text.template)
        #expect(restored.contains("href=\"https://example.com/x?a=1&amp;b=2\""))
        #expect(restored.contains("<code>let key = 42</code>"))
        #expect(restored.contains("https://example.org/path"))
    }

    @Test func lostInlineOrOpaqueMarkerRejected() {
        let text = BlockTranslationText(blockID: "b", html: "Use <code>foo()</code> and <a href='/x'>link</a>")
        #expect(throws: BlockTranslationError.markup("b")) { try text.restore("丢失标记") }
        #expect(throws: BlockTranslationError.markup("b")) { try text.restore(text.template + text.template) }
        #expect(throws: BlockTranslationError.markup("b")) { try text.restore(text.template + "⟬unknown⟭") }
        #expect(throws: BlockTranslationError.markup("b")) { try text.restore(text.template + "⟦broken⟧") }
    }

    @Test func modelHTMLIsEscapedAndCannotChangeLink() throws {
        let text = BlockTranslationText(blockID: "b", html: "<a href='/original'>Link</a>")
        let html = try text.restore(text.template + " <script>bad()</script>")
        #expect(html.contains("href='/original'"))
        #expect(!html.contains("<script>"))
        #expect(html.contains("&lt;script&gt;"))
    }

    @Test func imagesCodeTablesAreNotTranslationBlocks() throws {
        let image = HTMLMedia(url: URL(string: "https://example.com/image.png")!, title: nil,
                              caption: "A caption", posterURL: nil, aspectRatio: nil)
        let table = HTMLTable(rows: [.init(cells: [.init(html: "Table cell", isHeader: false)])])
        let doc = BlockReaderDocument(blocks: [.image(image), .codeBlock(code: "secretCode()", language: "swift"),
                                               .table(table), .text("Prose")], source: .rssFullContent, baseURL: nil)
        #expect(doc.texts.count == 2)
        let payload = try BlockTranslationProtocol.prompt(doc.texts)
        #expect(payload.contains("A caption"))
        #expect(!payload.contains("image.png"))
        #expect(!payload.contains("secretCode"))
        #expect(!payload.contains("Table cell"))
        let images = doc.nodes.compactMap { node -> HTMLMedia? in
            if case .unchanged(.image(let value)) = node { return value }; return nil
        }
        #expect(images.count == 1)
        #expect(images.first?.caption == nil)
        #expect(images.first?.url == image.url)
    }

    @Test func inlineCodeOnlyIsNotTranslated() {
        let doc = BlockReaderDocument(input: input(html: "<p><code>print(1)</code></p>"))
        #expect(doc.texts.isEmpty)
    }

    @Test func quoteAndListTopologyPreserved() {
        let doc = BlockReaderDocument(blocks: [.blockquote([.text("Quote"), .list(ordered: true, items: [[.text("First")], [.text("Second")]])])], source: .rssFullContent, baseURL: nil)
        #expect(doc.texts.count == 3)
        guard case .quote(let children) = doc.nodes.first,
              case .list(let ordered, let items) = children.last else { Issue.record("Lost nested structure"); return }
        #expect(ordered)
        #expect(items.count == 2)
        #expect(doc.document.blocks.filter { $0.kind == .quote }.count == 1)
        #expect(doc.document.blocks.filter { $0.kind == .listItem }.count == 2)
    }

    @Test func longArticleBatchesMultipleBlocks() throws {
        let blocks = BlockReaderDocument(input: input((0..<49).map { "Paragraph \($0) " + String(repeating: "words ", count: 120) })).texts
        let batches = try BlockTranslationProtocol.batches(blocks)
        #expect(batches.count > 1)
        #expect(batches.allSatisfy { (2...12).contains($0.count) })
        #expect(batches.flatMap { $0 }.map(\.blockID) == blocks.map(\.blockID))
    }

    @Test func smallBatchTailRedistributed() throws {
        let blocks = BlockReaderDocument(input: input((0..<5).map { "Paragraph \($0)" })).texts
        let batches = try BlockTranslationProtocol.batches(blocks, targetBytes: 1)
        #expect(batches.map(\.count) == [2, 3])
    }

    @Test func hugeBlockFailsBeforeRequest() {
        let blocks = BlockReaderDocument(input: input([String(repeating: "x", count: 48_001)])).texts
        #expect(throws: BlockTranslationError.tooLarge) { try BlockTranslationProtocol.batches(blocks) }
    }

    @Test func identityIncludesSourceOrderStructureAndURLs() {
        let a = BlockReaderDocument(input: input(html: "<p><a href='/a'>A</a></p><p>B</p>"))
        let b = BlockReaderDocument(input: input(html: "<p><a href='/b'>A</a></p><p>B</p>"))
        let c = BlockReaderDocument(input: input(html: "<p>B</p><p><a href='/a'>A</a></p>"))
        #expect(a.document.documentHash != b.document.documentHash)
        #expect(a.document.documentHash != c.document.documentHash)
        let list = BlockReaderDocument(blocks: [.list(ordered: false, items: [[.text("A")]])], source: .rssFullContent, baseURL: nil)
        let ordered = BlockReaderDocument(blocks: [.list(ordered: true, items: [[.text("A")]])], source: .rssFullContent, baseURL: nil)
        #expect(list.document.documentHash != ordered.document.documentHash)
    }

    @Test func cachePersistsAcrossInstances() async throws {
        let (cache, directory) = temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = input()
        let doc = BlockReaderDocument(input: source)
        let key = BlockTranslationCacheKey(input: source, document: doc.document, model: .flashLite)
        let values = Dictionary(uniqueKeysWithValues: doc.texts.map { ($0.blockID, "中文") })
        try await cache.store(values, key: key)
        let reloaded = await BlockTranslationCache(directory: directory).load(key, texts: doc.texts)
        #expect(reloaded == values)
    }

    @Test func modelAndContentChangesMissCache() async throws {
        let (cache, directory) = temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = input(), changed = input(["Changed"])
        let doc = BlockReaderDocument(input: source), other = BlockReaderDocument(input: changed)
        let key = BlockTranslationCacheKey(input: source, document: doc.document, model: .flashLite)
        try await cache.store([doc.texts[0].blockID: "中文"], key: key)
        let modelMiss = await cache.load(BlockTranslationCacheKey(input: source, document: doc.document, model: .flash), texts: doc.texts)
        let contentMiss = await cache.load(BlockTranslationCacheKey(input: changed, document: other.document, model: .flashLite), texts: other.texts)
        #expect(modelMiss.isEmpty)
        #expect(contentMiss.isEmpty)
    }

    @Test func cacheKeyCoversAllVersionsAndLanguage() {
        let source = input()
        let key = BlockTranslationCacheKey(input: source, document: BlockReaderDocument(input: source).document, model: .flashLite)
        var variants = [key, key, key, key]
        variants[0].provider = "other"
        variants[1].targetLanguage = "fr"
        variants[2].promptVersion += 1
        variants[3].blockSchemaVersion += 1
        #expect(variants.allSatisfy { $0.digest != key.digest })
        #expect(key.targetLanguage == "zh-Hans")
        let fragment = input(url: "https://example.com/article#part")
        #expect(BlockTranslationCacheKey(input: fragment, document: BlockReaderDocument(input: fragment).document, model: .flashLite).digest == key.digest)
        let different = input(url: "https://example.com/other")
        #expect(BlockTranslationCacheKey(input: different, document: BlockReaderDocument(input: different).document, model: .flashLite).digest != key.digest)
    }

    @Test func invalidCachedMappingIsMiss() async throws {
        let (cache, directory) = temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = input(), doc = BlockReaderDocument(input: input())
        let key = BlockTranslationCacheKey(input: source, document: doc.document, model: .flashLite)
        try await cache.store(["unknown": "中文"], key: key)
        #expect(await cache.load(key, texts: doc.texts).isEmpty)
        try await cache.store([doc.texts[0].blockID: ""], key: key)
        #expect(await cache.load(key, texts: doc.texts).isEmpty)
    }

    @Test func legacyMarkdownCacheStillRoundTrips() async {
        let template = MarkdownTranslationTemplate(title: "Legacy \(UUID())", blocks: [.text("Old paragraph")], baseURL: URL(string: "https://example.com/legacy"))
        await ArticleTranslationCache.shared.store(title: "旧标题", markdown: "旧正文", models: [.flashLite], template: template, language: "Chinese")
        let value = await ArticleTranslationCache.shared.value(for: template, language: "Chinese")
        #expect(value?.translatedTitle == "旧标题")
        #expect(value?.markdown == "旧正文")
        #expect(value?.models == [.flashLite])
    }
}

@Suite("Block reader request lifecycle") @MainActor
struct BlockReaderLifecycleTests {
    @Test func switchingAllModesNeverRequests() async {
        let (cache, directory) = temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let spy = TranslationSpy()
        let controller = BlockReaderTranslationController(cache: cache, transport: await spy.transport)
        await controller.load(input())
        for mode in BlockReaderMode.allCases { controller.mode = mode }
        #expect(await spy.calls.isEmpty)
        await controller.translate()
        #expect(controller.translatedCount == 2)
        for mode in BlockReaderMode.allCases { controller.mode = mode }
        await controller.translate()
        #expect(await spy.calls.count == 1)
    }

    @Test func secondOpenLoadsCacheWithoutRequests() async {
        let (cache, directory) = temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let spy = TranslationSpy()
        let first = BlockReaderTranslationController(cache: cache, transport: await spy.transport)
        await first.load(input())
        await first.translate()
        let second = BlockReaderTranslationController(cache: BlockTranslationCache(directory: directory), transport: await spy.transport)
        await second.load(input())
        #expect(second.isComplete)
        await second.translate()
        #expect(await spy.calls.count == 1)
    }

    @Test func partialFailureRetainsValidBatchesAndResumesMissingOnly() async {
        let (cache, directory) = temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let spy = TranslationSpy(failCall: 2)
        let source = input((0..<25).map { "Paragraph \($0)" })
        let first = BlockReaderTranslationController(cache: cache, transport: await spy.transport)
        await first.load(source)
        await first.translate()
        #expect(first.translatedCount == 12)
        #expect(first.message != nil)
        #expect(!first.isComplete)
        let savedIDs = Set(first.translatedHTML.keys)
        let second = BlockReaderTranslationController(cache: BlockTranslationCache(directory: directory), transport: await spy.transport)
        await second.load(source)
        #expect(second.translatedCount == 12)
        await second.translate()
        #expect(second.isComplete)
        let calls = await spy.calls
        #expect(calls.dropFirst(2).flatMap { $0 }.allSatisfy { !savedIDs.contains($0) })
    }

    @Test func invalidPartialResponseDoesNotCacheAnyOfBatch() async {
        let (cache, directory) = temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = BlockTranslationTransport { blocks, _ in try response([(blocks[0].blockID, "部分")]) }
        let controller = BlockReaderTranslationController(cache: cache, transport: transport)
        await controller.load(input())
        await controller.translate()
        #expect(controller.translatedCount == 0)
        #expect(controller.message != nil)
        let second = BlockReaderTranslationController(cache: cache, transport: transport)
        await second.load(input())
        #expect(second.translatedCount == 0)
    }

    @Test func changingContentOrModelClearsVisibleTranslations() async {
        let (cache, directory) = temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let spy = TranslationSpy()
        let controller = BlockReaderTranslationController(cache: cache, transport: await spy.transport)
        await controller.load(input())
        await controller.translate()
        await controller.load(input(), model: .flash)
        #expect(controller.translatedHTML.isEmpty)
        await controller.load(input(["Updated article"]))
        #expect(controller.translatedHTML.isEmpty)
        #expect(await spy.calls.count == 1)
    }

    @Test func lateResponseCannotApplyToChangedDocument() async {
        let (cache, directory) = temporaryCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = TranslationGate()
        let controller = BlockReaderTranslationController(cache: cache,
            transport: BlockTranslationTransport { blocks, _ in await gate.request(blocks) })
        await controller.load(input())
        let work = Task { await controller.translate() }
        await gate.waitUntilRequested()
        await controller.load(input(["New document"]))
        await gate.release()
        await work.value
        #expect(controller.translatedHTML.isEmpty)
        #expect(controller.totalCount == 1)
        #expect(!controller.isTranslating)
    }

    @Test func cacheWriteFailureIsVisibleWithoutDiscardingTranslation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("block-file-\(UUID())")
        try Data("not a directory".utf8).write(to: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let spy = TranslationSpy()
        let controller = BlockReaderTranslationController(cache: BlockTranslationCache(directory: directory), transport: await spy.transport)
        await controller.load(input())
        await controller.translate()
        #expect(controller.isComplete)
        #expect(controller.message?.contains("缓存写入失败") == true)
    }
}

private actor TranslationGate {
    var reply: CheckedContinuation<String, Never>?
    var waiter: CheckedContinuation<Void, Never>?
    var blocks: [BlockTranslationText] = []
    func request(_ blocks: [BlockTranslationText]) async -> String {
        self.blocks = blocks
        return await withCheckedContinuation { continuation in
            reply = continuation
            waiter?.resume()
            waiter = nil
        }
    }
    func waitUntilRequested() async {
        if reply != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() {
        reply?.resume(returning: try! response(blocks.map { ($0.blockID, "旧译文") }))
        reply = nil
    }
}
