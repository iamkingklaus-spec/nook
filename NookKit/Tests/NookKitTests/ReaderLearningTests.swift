import Foundation
import Testing
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
@testable import NookKit

private enum LearningFixture {
    static let wordJSON = #"{"type":"word","lemma":"bank","meaning":"河岸","englishDefinition":"the land beside a river","usage":"这里指河岸，不是银行。","example":"They sat on the bank."}"#
    static let sentenceJSON = #"{"type":"sentence","meaning":"他们沿着河岸行走。","mainClause":"They walked","grammar":["along 引出介词短语"],"phrases":["along the bank：沿河岸"],"pitfalls":["bank 在这里不是银行"]}"#
    static let text = "They walked along the bank. It was quiet."
    static func article(_ id: String = "a") -> LearningArticleContext {
        .init(articleID: id, articleURL: URL(string: "https://example.com/\(id)")!, title: "A walk", publisher: "News")
    }
    static func document(_ text: String = LearningFixture.text) -> ArticleDocument {
        ArticleDocument(source: .rssFullContent, blocks: [.init(kind: .paragraph, sourceContent: text)])
    }
    static func selection(_ text: String = LearningFixture.text, selected: String = "bank", articleID: String = "a") throws -> LearningSelection {
        let doc = document(text)
        return try #require(LearningSelection.resolve(article: article(articleID), document: doc,
            blockID: doc.blocks[0].id, renderedSource: text, range: (text as NSString).range(of: selected)))
    }
    static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "learning-test-\(UUID())")
    }
    static func explanation() throws -> LearningExplanation { try LearningExplanationProtocol.decode(wordJSON, type: .word) }
}

@Suite("Reader learning selection and protocol")
struct LearningSelectionTests {
    @Test func selectableSourceKeepsReaderLineSpacingWithoutMutatingCache() throws {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 0; style.paragraphSpacing = 7
        let source = NSAttributedString(string: "A linked bank", attributes: [.paragraphStyle: style])
        let rendered = LearningTextLayout.applyingLineSpacing(source, spacing: 6)
        let changed = try #require(rendered.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        #expect(changed.lineSpacing == 6 && changed.paragraphSpacing == 7)
        #expect(style.lineSpacing == 0)
        #expect(rendered.string == source.string)
    }
    @Test func selectableSourcePreservesLinkURLs() {
        let url = URL(string: "https://example.com/original")!
        let source = NSAttributedString(string: "bank", attributes: [.link: url])
        let rendered = LearningTextLayout.applyingLineSpacing(source, spacing: 4)
        #expect(rendered.attribute(.link, at: 0, effectiveRange: nil) as? URL == url)
    }
    @Test func wordUsesStableSourceBlockIdentity() throws {
        let selection = try LearningFixture.selection()
        #expect(selection.isWord)
        #expect(selection.blockID == LearningFixture.document().blocks[0].id)
        #expect(selection.documentHash == LearningFixture.document().documentHash)
        #expect(selection.sentence == "They walked along the bank.")
    }
    @Test func sentenceSelectionRetainsSourceText() throws {
        let selected = "They walked along the bank."
        let selection = try LearningFixture.selection(selected: selected)
        #expect(!selection.isWord)
        #expect(selection.selectedText == selected)
        #expect(selection.sentence == selected)
    }
    @Test func partialWordCannotUseWordExplanation() throws {
        let selection = try LearningFixture.selection(selected: "ank")
        #expect(!selection.isWord)
    }
    @Test @MainActor func bilingualModesPreserveEnglishSourceMappingWithoutRequests() async throws {
        let root = LearningFixture.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let translator = BlockReaderTranslationController(cache: BlockTranslationCache(directory: root),
            transport: BlockTranslationTransport { _, _ in Issue.record("Mode change must not translate"); return "" })
        await translator.load(BlockReaderInput(articleID: "a", url: LearningFixture.article().articleURL,
            html: nil, paragraphs: [LearningFixture.text], source: .rssFullContent))
        let document = try #require(translator.prepared?.document)
        var selections: [LearningSelection] = []
        for mode in [BlockReaderMode.english, .bilingual, .chinese, .bilingual] {
            translator.mode = mode
            let current = try #require(translator.prepared?.document)
            selections.append(try #require(LearningSelection.resolve(article: LearningFixture.article(), document: current,
                blockID: document.blocks[0].id, renderedSource: LearningFixture.text,
                range: (LearningFixture.text as NSString).range(of: "bank"))))
        }
        #expect(selections.allSatisfy { $0 == selections[0] })
    }
    @Test func repeatedWordsUseExactSelectedOccurrence() throws {
        let text = "The bank lent money. We sat on the bank."
        let doc = LearningFixture.document(text)
        let range = (text as NSString).range(of: "bank", options: .backwards)
        let selection = try #require(LearningSelection.resolve(article: LearningFixture.article(), document: doc,
            blockID: doc.blocks[0].id, renderedSource: text, range: range))
        #expect(selection.sentence == "We sat on the bank.")
        #expect(selection.offset == range.location)
    }
    @Test func bilingualTranslationCannotBecomeSourceSelection() {
        let doc = LearningFixture.document()
        #expect(LearningSelection.resolve(article: LearningFixture.article(), document: doc,
            blockID: doc.blocks[0].id, renderedSource: "bank 是河岸", range: NSRange(location: 0, length: 4), origin: .translation) == nil)
    }
    @Test func chineseSelectionIsNotEnglishLearning() {
        let doc = LearningFixture.document("河岸")
        #expect(LearningSelection.resolve(article: LearningFixture.article(), document: doc,
            blockID: doc.blocks[0].id, renderedSource: "河岸", range: NSRange(location: 0, length: 2)) == nil)
    }
    @Test func invalidRangeAndUnknownBlockAreRejected() {
        let doc = LearningFixture.document()
        for range in [NSRange(location: NSNotFound, length: 1), NSRange(location: 0, length: 0), NSRange(location: 900, length: 5)] {
            #expect(LearningSelection.resolve(article: LearningFixture.article(), document: doc,
                blockID: doc.blocks[0].id, renderedSource: LearningFixture.text, range: range) == nil)
        }
        #expect(LearningSelection.resolve(article: LearningFixture.article(), document: doc,
            blockID: "unknown", renderedSource: LearningFixture.text, range: NSRange(location: 0, length: 4)) == nil)
    }
    @Test func codeAndOtherNonProseCannotBeExplained() {
        for kind in [ArticleBlock.Kind.code, .image, .other] {
            let doc = ArticleDocument(source: .rssFullContent, blocks: [.init(kind: kind, sourceContent: "bank")])
            #expect(LearningSelection.resolve(article: LearningFixture.article(), document: doc,
                blockID: doc.blocks[0].id, renderedSource: "bank", range: NSRange(location: 0, length: 4)) == nil)
        }
    }
    @Test func promptIsBoundedAndContainsNoArticleURLOrOtherParagraphs() throws {
        let text = String(repeating: "left ", count: 2000) + "bank" + String(repeating: " right", count: 2000)
        let selection = try LearningFixture.selection(text)
        let prompt = try LearningExplanationProtocol.prompt(selection, type: .word)
        #expect(selection.blockContext.count <= 2004)
        #expect(selection.sentence.count <= 1400)
        #expect(!prompt.contains("https://"))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(prompt.utf8)) as? [String: String])
        #expect(Set(object.keys) == ["type", "selectedText", "containingSentence", "containingBlock", "articleTitle"])
    }
    @Test func validWordResponse() throws {
        let result = try LearningFixture.explanation()
        #expect(result.lemma == "bank")
        #expect(result.meaning == "河岸")
    }
    @Test func validSentenceResponse() throws {
        let result = try LearningExplanationProtocol.decode(LearningFixture.sentenceJSON, type: .sentence)
        #expect(result.mainClause == "They walked")
        #expect(result.grammar?.count == 1)
    }
    @Test func malformedResponsesAreRejected() {
        for response in ["not JSON", "```json\n\(LearningFixture.wordJSON)\n```", "{}", "[]",
                         LearningFixture.wordJSON.replacingOccurrences(of: "河岸", with: ""),
                         LearningFixture.wordJSON.replacingOccurrences(of: "\"usage\"", with: "\"unexpected\"")] {
            #expect(throws: LearningError.self) { try LearningExplanationProtocol.decode(response, type: .word) }
        }
    }
    @Test func wrongExplanationTypeCannotBeCached() {
        #expect(throws: LearningError.self) { try LearningExplanationProtocol.decode(LearningFixture.sentenceJSON, type: .word) }
    }
    @Test func emptySentenceArraysAreAllowed() throws {
        let json = #"{"type":"sentence","meaning":"你好。","mainClause":"Hello","grammar":[],"phrases":[],"pitfalls":[]}"#
        let value = try LearningExplanationProtocol.decode(json, type: .sentence)
        #expect(value.pitfalls == [])
    }
    @Test func cacheKeySeparatesTypeModelDocumentAndArticle() throws {
        let selection = try LearningFixture.selection()
        let key = LearningCacheKey(selection: selection, type: .word, model: "one")
        #expect(key != LearningCacheKey(selection: selection, type: .sentence, model: "one"))
        #expect(key != LearningCacheKey(selection: selection, type: .word, model: "two"))
        #expect(key != LearningCacheKey(selection: try LearningFixture.selection(LearningFixture.text + " New."), type: .word, model: "one"))
        #expect(key != LearningCacheKey(selection: try LearningFixture.selection(articleID: "b"), type: .word, model: "one"))
    }
}

@Suite("Vocabulary local persistence") @MainActor
struct VocabularyPersistenceTests {
    @Test func vocabularyRoundTripPreservesAllSourceMetadata() throws {
        let root = LearningFixture.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ReaderLearningStore(directory: root)
        let selection = try LearningFixture.selection()
        let saved = try store.save(selection: selection, explanation: LearningFixture.explanation())
        let reloaded = ReaderLearningStore(directory: root)
        #expect(reloaded.entries == [saved])
        #expect(saved.documentHash == selection.documentHash && saved.blockID == selection.blockID)
        #expect(saved.articleID == "a" && saved.publisher == "News" && saved.articleTitle == "A walk")
        #expect(saved.word == "bank" && saved.lemma == "bank" && saved.meaning == "河岸")
        #expect(saved.originalSentence == selection.sentence && saved.articleURL == selection.article.articleURL)
    }
    @Test func duplicateSaveReturnsExistingEntry() throws {
        let root = LearningFixture.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ReaderLearningStore(directory: root)
        let a = try store.save(selection: LearningFixture.selection(), explanation: LearningFixture.explanation())
        let b = try store.save(selection: LearningFixture.selection(), explanation: LearningFixture.explanation())
        #expect(a == b && store.entries.count == 1)
    }
    @Test func sameWordDifferentContextIsRetained() throws {
        let root = LearningFixture.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ReaderLearningStore(directory: root)
        try store.save(selection: LearningFixture.selection(), explanation: LearningFixture.explanation())
        try store.save(selection: LearningFixture.selection("She works at the bank."), explanation: LearningFixture.explanation())
        #expect(store.entries.count == 2)
    }
    @Test func deletionSurvivesReload() throws {
        let root = LearningFixture.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ReaderLearningStore(directory: root)
        let entry = try store.save(selection: LearningFixture.selection(), explanation: LearningFixture.explanation())
        try store.delete(entry.id)
        #expect(store.entries.isEmpty)
        #expect(ReaderLearningStore(directory: root).entries.isEmpty)
    }
    @Test func searchMatchesWordMeaningSentenceAndSource() throws {
        let root = LearningFixture.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ReaderLearningStore(directory: root)
        try store.save(selection: LearningFixture.selection(), explanation: LearningFixture.explanation())
        for query in ["BANK", "河岸", "walked", "News", "A walk"] { #expect(store.search(query).count == 1) }
        #expect(store.search("absent").isEmpty)
    }
    @Test func corruptVocabularyIsPreservedAndCannotBeOverwritten() throws {
        let root = LearningFixture.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appending(path: "vocabulary.json")
        let original = Data("broken".utf8); try original.write(to: url)
        let store = ReaderLearningStore(directory: root)
        #expect(store.loadError != nil)
        let selection = try LearningFixture.selection(), explanation = try LearningFixture.explanation()
        #expect(throws: LearningError.self) { try store.save(selection: selection, explanation: explanation) }
        #expect(try Data(contentsOf: url) == original)
    }
    @Test func cacheSurvivesReloadAndMissesChangedContent() throws {
        let root = LearningFixture.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ReaderLearningStore(directory: root)
        let key = LearningCacheKey(selection: try LearningFixture.selection(), type: .word, model: "model")
        try store.cache(LearningFixture.explanation(), for: key)
        let reloaded = ReaderLearningStore(directory: root)
        #expect(reloaded.cached(key, type: .word)?.meaning == "河岸")
        let changed = LearningCacheKey(selection: try LearningFixture.selection(LearningFixture.text + " New."), type: .word, model: "model")
        #expect(reloaded.cached(changed, type: .word) == nil)
        #expect(reloaded.cached(key, type: .sentence) == nil)
        #expect(reloaded.entries.isEmpty)
    }
    @Test func failedWriteDoesNotPretendVocabularyWasSaved() throws {
        let root = LearningFixture.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        try Data("file".utf8).write(to: root)
        let store = ReaderLearningStore(directory: root)
        let selection = try LearningFixture.selection(), explanation = try LearningFixture.explanation()
        #expect(throws: (any Error).self) { try store.save(selection: selection, explanation: explanation) }
        #expect(store.entries.isEmpty)
    }
}

private actor LearningSpy {
    var calls = 0
    var response = LearningFixture.wordJSON
    func reply() -> String { calls += 1; return response }
    func set(_ value: String) { response = value }
    var transport: LearningTransport { LearningTransport { _, _, _ in await self.reply() } }
}
private actor LearningGate {
    var continuation: CheckedContinuation<String, Never>?
    func reply() async -> String { await withCheckedContinuation { continuation = $0 } }
    func wait() async { while continuation == nil { await Task.yield() } }
    func release() { continuation?.resume(returning: LearningFixture.wordJSON); continuation = nil }
}

@Suite("Reader learning explicit requests") @MainActor
struct LearningPipelineTests {
    @Test func openingControllerMakesNoRequest() async {
        let spy = LearningSpy()
        let controller = ReaderLearningController(store: ReaderLearningStore(directory: LearningFixture.temporaryDirectory()), transport: await spy.transport)
        #expect(!controller.isLoading && controller.result == nil)
        #expect(await spy.calls == 0)
    }
    @Test func secondExplanationAndReopenUseCache() async throws {
        let root = LearningFixture.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let spy = LearningSpy(), store = ReaderLearningStore(directory: root)
        let controller = ReaderLearningController(store: store, transport: await spy.transport)
        let selection = try LearningFixture.selection()
        await controller.explain(selection, type: .word)
        #expect(!controller.cacheHit && controller.result != nil)
        await controller.explain(selection, type: .word)
        #expect(controller.cacheHit)
        let reopened = ReaderLearningController(store: ReaderLearningStore(directory: root), transport: await spy.transport)
        await reopened.explain(selection, type: .word)
        #expect(reopened.cacheHit)
        #expect(await spy.calls == 1)
    }
    @Test func modelAndDocumentChangesRequestNewExplanation() async throws {
        let root = LearningFixture.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let spy = LearningSpy()
        let controller = ReaderLearningController(store: ReaderLearningStore(directory: root), transport: await spy.transport)
        await controller.explain(try LearningFixture.selection(), type: .word)
        await controller.explain(try LearningFixture.selection(), type: .word, model: .flash)
        await controller.explain(try LearningFixture.selection(LearningFixture.text + " New."), type: .word)
        #expect(await spy.calls == 3)
    }
    @Test func malformedResponseIsNotCachedAndRetrySucceeds() async throws {
        let root = LearningFixture.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let spy = LearningSpy(); await spy.set("bad JSON")
        let controller = ReaderLearningController(store: ReaderLearningStore(directory: root), transport: await spy.transport)
        let selection = try LearningFixture.selection()
        await controller.explain(selection, type: .word)
        #expect(controller.result == nil && controller.message != nil)
        await spy.set(LearningFixture.wordJSON)
        await controller.explain(selection, type: .word)
        #expect(controller.result != nil && controller.message == nil)
        #expect(await spy.calls == 2)
    }
    @Test func cancellationRejectsLateResponseAndDoesNotCache() async throws {
        let root = LearningFixture.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ReaderLearningStore(directory: root), gate = LearningGate()
        let controller = ReaderLearningController(store: store, transport: LearningTransport { _, _, _ in await gate.reply() })
        let selection = try LearningFixture.selection()
        let task = Task { await controller.explain(selection, type: .word) }
        await gate.wait()
        controller.cancel()
        await gate.release(); await task.value
        #expect(controller.result == nil && !controller.isLoading)
        #expect(store.cached(LearningCacheKey(selection: selection, type: .word, model: GeminiTranslator.model), type: .word) == nil)
        let spy = LearningSpy()
        let retry = ReaderLearningController(store: store, transport: await spy.transport)
        await retry.explain(selection, type: .word)
        #expect(retry.result != nil && !retry.cacheHit)
    }
    @Test func newerSelectionCannotReceiveOlderResponse() async throws {
        let root = LearningFixture.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = LearningGate(), spy = LearningSpy()
        let controller = ReaderLearningController(store: ReaderLearningStore(directory: root), transport: LearningTransport { _, prompt, _ in
            if prompt.contains("quiet") { return await gate.reply() }
            return await spy.reply()
        })
        let first = try LearningFixture.selection(), second = try LearningFixture.selection("We sat on the bank.")
        let task = Task { await controller.explain(first, type: .word) }
        await gate.wait()
        await controller.explain(second, type: .word)
        await gate.release(); await task.value
        #expect(controller.selection == second && controller.result != nil)
    }
    @Test func sentenceUsesSameCacheWithoutSavingVocabulary() async throws {
        let root = LearningFixture.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let spy = LearningSpy(); await spy.set(LearningFixture.sentenceJSON)
        let store = ReaderLearningStore(directory: root)
        let controller = ReaderLearningController(store: store, transport: await spy.transport)
        let selection = try LearningFixture.selection(selected: "They walked along the bank.")
        await controller.explain(selection, type: .sentence)
        await controller.explain(selection, type: .sentence)
        #expect(controller.cacheHit && store.entries.isEmpty)
        #expect(await spy.calls == 1)
    }
    @Test func sentenceCannotUseWordAction() async throws {
        let spy = LearningSpy()
        let controller = ReaderLearningController(store: ReaderLearningStore(directory: LearningFixture.temporaryDirectory()), transport: await spy.transport)
        await controller.explain(try LearningFixture.selection(selected: "They walked along the bank."), type: .word)
        #expect(controller.message != nil)
        #expect(await spy.calls == 0)
    }
}
