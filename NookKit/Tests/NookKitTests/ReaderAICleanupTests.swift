import Foundation
import Testing
@testable import NookKit

private func cleanupResponse(_ entries: [(String, String)]) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: ["decisions": entries.map {
        ["blockID": $0.0, "decision": $0.1]
    }]), as: UTF8.self)
}
private func cleanupInput(_ paragraphs: [String] = ["English reporting one.", "English reporting two."]) -> BlockReaderInput {
    .init(articleID: "ai-cleanup", url: URL(string: "https://example.org/article")!, html: nil,
          paragraphs: paragraphs, source: .extractedReaderContent)
}
private func cleanupDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("cleanup-tests-\(UUID())", isDirectory: true)
}
private func cleanupCandidates() -> [ReaderAICleanup.Candidate] {
    ["A", "B", "C"].map { .init(blockID: $0, kind: "paragraph", text: "English \($0)") }
}

@Suite("Reversible AI reader cleanup")
struct ReaderAICleanupTests {
    @Test func reorderedDecisionsUseIDs() throws {
        let values = try ReaderAICleanup.decode(cleanupResponse([("C", "keep"), ("B", "hide"), ("A", "keep")]), expected: cleanupCandidates())
        #expect(values == ["A": .keep, "B": .hide, "C": .keep])
    }

    @Test func missingAndDuplicateDecisionsStayUnresolved() throws {
        let values = try ReaderAICleanup.decode(cleanupResponse([("A", "hide"), ("A", "keep"), ("B", "keep")]), expected: cleanupCandidates())
        #expect(values == ["B": .keep])
    }

    @Test func unknownIDCannotSelectAnySourceBlock() {
        #expect(throws: BlockTranslationError.self) {
            try ReaderAICleanup.decode(cleanupResponse([("invented", "hide")]), expected: cleanupCandidates())
        }
    }

    @Test func malformedOrRewrittenResponsesAreRejected() throws {
        #expect(throws: BlockTranslationError.self) { try ReaderAICleanup.decode("not JSON", expected: cleanupCandidates()) }
        let values = try ReaderAICleanup.decode("""
        {"decisions":[{"blockID":"A","decision":"hide","rewrittenText":"new story"},{"blockID":"B","decision":"delete"}]}
        """, expected: cleanupCandidates())
        #expect(values.isEmpty)
    }

    @Test func screenshotDebrisCanBeMaskedWithoutChangingSourceIdentity() throws {
        // Structural fixture of the screenshot, not a captured publisher DOM.
        let blocks: [HTMLContentBlock] = [
            .text("English caption about the council meeting."),
            .text("Photograph: Finnbarr Webster/Getty Images People outside a council meeting. Photograph: Finnbarr Webster/Getty Images"),
            .text("<a href='/topic'>Datacentres - UK</a>"),
            .image(HTMLMedia(url: URL(string: "https://example.org/author.jpg")!, title: nil,
                             caption: nil, posterURL: nil, aspectRatio: nil, declaredWidth: nil)),
            .text("<a href='/author'>Sandra Laville</a>"),
            .text("Sun 27 Sep 2026 08.00 BST"),
            .text("Last modified on Sun 27 Sep 2026 11.02 BST"),
            .text("English reporting about the <a href='/council'>council</a>.")]
        let doc = BlockReaderDocument(blocks: blocks, source: .extractedReaderContent, baseURL: cleanupInput().url)
        let candidates = ReaderAICleanup.candidates(doc)
        let decisions = Dictionary(uniqueKeysWithValues: candidates.map {
            ($0.blockID, $0.text.hasPrefix("English") ? ReaderAICleanup.Decision.keep : .hide)
        })
        let cleaned = ReaderAICleanup.filtered(doc, decisions: decisions)
        #expect(cleaned.document == doc.document)
        #expect(cleaned.nodes.count == 2)
        #expect(cleaned.texts.count == 2)
        let last = try #require(cleaned.texts.last)
        #expect(try last.restore(last.template).contains("href='/council'"))
        let oldTranslations = Dictionary(uniqueKeysWithValues: doc.texts.map { ($0.blockID, "旧译文") })
        #expect(BlockReaderPresentation.nodes(cleaned.nodes, translations: oldTranslations, templates: [:]).count == 2)
    }

    @Test func codeTablesAndMediaTargetsNeverEnterPrompt() throws {
        let doc = BlockReaderDocument(input: .init(articleID: "code", url: cleanupInput().url,
            html: "<p>English <a href='https://private.example/link'>link</a> with <code>secretCode()</code>.</p><pre>secretProgram()</pre><table><tr><td>secretTable</td></tr></table><img src='https://private.example/photo.jpg'>",
            paragraphs: [], source: .extractedReaderContent))
        let candidates = ReaderAICleanup.candidates(doc)
        let prompt = try ReaderAICleanup.prompt(candidates, all: candidates)
        for secret in ["private.example", "secretCode", "secretProgram", "secretTable"] { #expect(!prompt.contains(secret)) }
        let kept = ReaderAICleanup.filtered(doc, decisions: Dictionary(uniqueKeysWithValues: candidates.map { ($0.blockID, .keep) }))
        #expect(kept.nodes.count == doc.nodes.count)
    }

    @Test func missingDecisionKeepsOriginalButDoesNotSpendTranslationTokens() {
        let doc = BlockReaderDocument(input: cleanupInput())
        let cleaned = ReaderAICleanup.filtered(doc, decisions: [:])
        #expect(cleaned.nodes.count == doc.nodes.count)
        #expect(cleaned.texts.isEmpty)
    }

    @Test func quoteListAndQAOrderArePreserved() throws {
        let doc = BlockReaderDocument(blocks: [.heading(level: 2, html: "English heading"),
            .blockquote([.text("English quote")]), .list(ordered: true, items: [[.text("English item")]]),
            .text("Q: Will you share more?"), .text("The answer follows from the report.")],
            source: .extractedReaderContent, baseURL: cleanupInput().url)
        let candidates = ReaderAICleanup.candidates(doc)
        let kept = ReaderAICleanup.filtered(doc, decisions: Dictionary(uniqueKeysWithValues: candidates.map { ($0.blockID, .keep) }))
        #expect(kept.texts.map(\.blockID) == doc.texts.map(\.blockID))
        if case .quote = kept.nodes[1] {} else { Issue.record("Quote structure lost") }
        if case .list(let ordered, _) = kept.nodes[2] { #expect(ordered) } else { Issue.record("List structure lost") }
    }

    @Test func longCleanupUsesMultipleBlocksAndKeepsOriginalNeighborhoodOnRetry() throws {
        let all = (0..<70).map { ReaderAICleanup.Candidate(blockID: "id\($0)", kind: "paragraph", text: "English \($0)") }
        #expect(ReaderAICleanup.batches(all).map(\.count) == [32, 32, 6])
        let prompt = try ReaderAICleanup.prompt([all[5], all[8]], all: all)
        let root = try #require(JSONSerialization.jsonObject(with: Data(prompt.utf8)) as? [String: Any])
        let context = try #require(root["context"] as? [[String: String]])
        #expect(context.contains { $0["blockID"] == "id7" })
        #expect(!context.contains { $0["blockID"] == "id5" })
    }

    @Test func cleanupCacheChangesWithModelContentAndCredit() {
        let input = cleanupInput(), doc = BlockReaderDocument(input: cleanupInput())
        let candidates = ReaderAICleanup.candidates(doc)
        let key = BlockTranslationCacheKey(input: input, document: doc.document, model: .flashLite)
        let first = ReaderCleanupCache.identity(key, candidates: candidates)
        #expect(first != ReaderCleanupCache.identity(.init(input: input, document: doc.document, model: .flash), candidates: candidates))
        #expect(first != ReaderCleanupCache.identity(key, candidates: candidates + [.init(blockID: "credit", kind: "photoCredit", text: "New credit")]))
        let changed = BlockReaderDocument(input: cleanupInput(["Changed English article"]))
        #expect(first != ReaderCleanupCache.identity(.init(input: input, document: changed.document, model: .flashLite), candidates: candidates))
    }
}

private actor CleanupSpy {
    var cleanupCalls: [[String]] = []
    var translationCalls: [[String]] = []
    let omitFirst: Bool
    let failAt: Int?
    init(omitFirst: Bool = false, failAt: Int? = nil) { self.omitFirst = omitFirst; self.failAt = failAt }
    func clean(_ blocks: [ReaderAICleanup.Candidate]) throws -> String {
        cleanupCalls.append(blocks.map(\.blockID))
        if cleanupCalls.count == failAt { throw URLError(.notConnectedToInternet) }
        let selected = omitFirst && cleanupCalls.count == 1 ? Array(blocks.dropLast()) : blocks
        return try cleanupResponse(selected.reversed().map { ($0.blockID, $0.text == "Promotional module" ? "hide" : "keep") })
    }
    func translate(_ blocks: [BlockTranslationText]) throws -> String {
        translationCalls.append(blocks.map(\.blockID))
        return String(decoding: try JSONSerialization.data(withJSONObject: ["translations": blocks.map {
            ["blockID": $0.blockID, "translatedText": $0.template.replacingOccurrences(of: "English", with: "中文")]
        }]), as: UTF8.self)
    }
}

@Suite("Automatic bilingual reader lifecycle") @MainActor
struct AutomaticReaderTests {
    private func controller(_ directory: URL, spy: CleanupSpy) -> BlockReaderTranslationController {
        .init(cache: BlockTranslationCache(directory: directory.appendingPathComponent("translation")),
            transport: .init { blocks, _ in try await spy.translate(blocks) },
            cleanupTransport: .init { blocks, _, _ in try await spy.clean(blocks) },
            cleanupCache: ReaderCleanupCache(directory: directory.appendingPathComponent("cleanup")))
    }

    @Test func openingDefaultsToBilingualAndModesDoNotRequestAgain() async {
        let directory = cleanupDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let spy = CleanupSpy()
        let reader = controller(directory, spy: spy)
        // A plain load remains usable by manual/legacy callers without networking.
        await reader.load(cleanupInput())
        #expect(!reader.isTranslating)
        #expect(await spy.cleanupCalls.isEmpty)
        #expect(await spy.translationCalls.isEmpty)
        let automatic = controller(directory, spy: spy)
        await automatic.open(cleanupInput())
        #expect(automatic.mode == .bilingual)
        #expect(automatic.isComplete)
        for mode in BlockReaderMode.allCases { automatic.mode = mode }
        await automatic.translate()
        #expect(await spy.cleanupCalls.count == 1)
        #expect(await spy.translationCalls.count == 1)
    }

    @Test func secondOpenReadsBothCachesWithoutRequests() async {
        let directory = cleanupDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let spy = CleanupSpy()
        await controller(directory, spy: spy).open(cleanupInput())
        let reopened = controller(directory, spy: spy)
        await reopened.open(cleanupInput())
        #expect(reopened.isComplete)
        #expect(await spy.cleanupCalls.count == 1)
        #expect(await spy.translationCalls.count == 1)
    }

    @Test func hiddenBlockCannotReachTranslationOrBilingualRendering() async {
        let directory = cleanupDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let spy = CleanupSpy(), input = cleanupInput(["English article body", "Promotional module"])
        let reader = controller(directory, spy: spy)
        await reader.open(input)
        #expect(reader.prepared?.nodes.count == 1)
        #expect(reader.totalCount == 1)
        #expect(await spy.translationCalls.first?.count == 1)
    }

    @Test func missingDecisionsRetryOnlyUnresolvedAndUntranslatedBlocks() async {
        let directory = cleanupDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let spy = CleanupSpy(omitFirst: true)
        let partial = controller(directory, spy: spy)
        await partial.open(cleanupInput())
        #expect(partial.cleanupPending)
        #expect(partial.translatedCount == 1)
        #expect(!partial.isComplete)
        await partial.translate()
        #expect(partial.isComplete)
        #expect(await spy.cleanupCalls.map(\.count) == [2, 1])
        #expect(await spy.translationCalls.map(\.count) == [1, 1])
    }

    @Test func laterCleanupFailurePersistsEarlierDecisionsForReopen() async {
        let directory = cleanupDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let spy = CleanupSpy(failAt: 2), input = cleanupInput((0..<40).map { "English paragraph \($0)" })
        let first = controller(directory, spy: spy)
        await first.open(input)
        #expect(first.cleanupPending)
        #expect(first.prepared?.nodes.count == 40)
        #expect(await spy.translationCalls.isEmpty)
        let second = controller(directory, spy: spy)
        await second.open(input)
        #expect(second.isComplete)
        #expect(await spy.cleanupCalls.map(\.count) == [32, 8, 8])
    }

    @Test func failedCleanupShowsOriginalAndOffersRetry() async {
        let directory = cleanupDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let spy = CleanupSpy(failAt: 1)
        let failing = controller(directory, spy: spy)
        await failing.open(cleanupInput())
        #expect(failing.prepared?.nodes.count == 2)
        #expect(failing.cleanupPending && !failing.isCleaning)
        #expect(failing.message != nil)
        #expect(await spy.translationCalls.isEmpty)
        await failing.translate()
        #expect(failing.isComplete)
    }

    @Test func classifierCannotHideEntireStory() async {
        let directory = cleanupDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let reader = BlockReaderTranslationController(cache: .init(directory: directory),
            transport: .init { _, _ in Issue.record("Must not translate after invalid cleanup"); return "" },
            cleanupTransport: .init { batch, _, _ in try cleanupResponse(batch.map { ($0.blockID, "hide") }) },
            cleanupCache: .init(directory: directory.appendingPathComponent("cleanup")))
        await reader.open(cleanupInput())
        #expect(reader.prepared?.nodes.count == 2)
        #expect(reader.cleanupPending)
    }

    @Test func resetCancelsCleanupAndLateResponseCannotTranslate() async {
        let directory = cleanupDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let gate = CleanupGate()
        let reader = BlockReaderTranslationController(cache: .init(directory: directory),
            transport: .init { _, _ in Issue.record("Cancelled article translated"); return "" },
            cleanupTransport: .init { batch, _, _ in await gate.request(batch) },
            cleanupCache: .init(directory: directory.appendingPathComponent("cleanup")))
        let task = Task { await reader.open(cleanupInput()) }
        await gate.started()
        reader.reset()
        await gate.finish()
        await task.value
        #expect(reader.prepared == nil)
        #expect(!reader.isCleaning && !reader.isTranslating)
        #expect(await gate.sawCancellation)
    }

    @Test func existingTranslationsAreReusedButHiddenOnNewCleanupMask() async throws {
        let directory = cleanupDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let input = cleanupInput(["English body", "Promotional module"])
        let doc = BlockReaderDocument(input: input)
        let key = BlockTranslationCacheKey(input: input, document: doc.document, model: .flashLite)
        let cache = BlockTranslationCache(directory: directory.appendingPathComponent("translation"))
        try await cache.store(Dictionary(uniqueKeysWithValues: doc.texts.map { ($0.blockID, $0.template) }), key: key)
        let spy = CleanupSpy(), reader = controller(directory, spy: CleanupSpy())
        await reader.load(input)
        #expect(reader.isComplete)
        let automatic = controller(directory, spy: spy)
        await automatic.open(input)
        #expect(automatic.translatedCount == 1)
        #expect(automatic.presentationTranslations.count == 1)
        #expect(await spy.translationCalls.isEmpty)
    }

    @Test func cancellationDuringTranslationKeepsSuccessfulBatchForNextOpen() async {
        let directory = cleanupDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let input = cleanupInput((0..<17).map { "English paragraph \($0)" })
        let spy = CleanupSpy(), gate = CleanupGate()
        let reader = BlockReaderTranslationController(
            cache: .init(directory: directory.appendingPathComponent("translation")),
            transport: .init { blocks, _ in
                let reply = try await spy.translate(blocks)
                if await spy.translationCalls.count == 2 { _ = await gate.request([]) }
                return reply
            }, cleanupTransport: .init { batch, _, _ in try await spy.clean(batch) },
            cleanupCache: .init(directory: directory.appendingPathComponent("cleanup")))
        let task = Task { await reader.open(input) }
        await gate.started()
        #expect(reader.translatedCount == 12)
        reader.reset()
        await gate.finish()
        await task.value
        let reopened = controller(directory, spy: spy)
        await reopened.open(input)
        #expect(reopened.translatedCount == 17)
        #expect(await spy.cleanupCalls.count == 1)
        #expect(await spy.translationCalls.map(\.count) == [12, 5, 5])
    }
}

private actor CleanupGate {
    var continuation: CheckedContinuation<String, Never>?
    var waiter: CheckedContinuation<Void, Never>?
    var batch: [ReaderAICleanup.Candidate] = []
    var sawCancellation = false
    func request(_ batch: [ReaderAICleanup.Candidate]) async -> String {
        self.batch = batch
        let value = await withCheckedContinuation { continuation in
            self.continuation = continuation; waiter?.resume(); waiter = nil
        }
        sawCancellation = Task.isCancelled
        return value
    }
    func started() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func finish() {
        continuation?.resume(returning: try! cleanupResponse(batch.map { ($0.blockID, "keep") }))
        continuation = nil
    }
}
