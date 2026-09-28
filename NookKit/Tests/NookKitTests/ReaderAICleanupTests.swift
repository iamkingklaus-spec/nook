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

    @Test func missingDecisionKeepsOriginalAvailableForTranslation() {
        let doc = BlockReaderDocument(input: cleanupInput())
        let cleaned = ReaderAICleanup.filtered(doc, decisions: [:])
        #expect(cleaned.nodes.count == doc.nodes.count)
        #expect(cleaned.texts.map(\.blockID) == doc.texts.map(\.blockID))
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
        #expect(ReaderAICleanup.batches(all).map(\.count) == [12, 12, 12, 12, 12, 10])
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
    let translationFailAt: Int?
    init(omitFirst: Bool = false, failAt: Int? = nil, translationFailAt: Int? = nil) {
        self.omitFirst = omitFirst; self.failAt = failAt; self.translationFailAt = translationFailAt
    }
    func clean(_ blocks: [ReaderAICleanup.Candidate]) throws -> String {
        cleanupCalls.append(blocks.map(\.blockID))
        if cleanupCalls.count == failAt { throw URLError(.notConnectedToInternet) }
        let selected = omitFirst && cleanupCalls.count == 1 ? Array(blocks.dropLast()) : blocks
        return try cleanupResponse(selected.reversed().map { ($0.blockID, $0.text == "Promotional module" ? "hide" : "keep") })
    }
    func translate(_ blocks: [BlockTranslationText]) throws -> String {
        translationCalls.append(blocks.map(\.blockID))
        if translationCalls.count == translationFailAt { throw URLError(.timedOut) }
        return String(decoding: try JSONSerialization.data(withJSONObject: ["translations": blocks.map {
            ["blockID": $0.blockID, "translatedText": $0.template.replacingOccurrences(of: "English", with: "中文")]
        }]), as: UTF8.self)
    }
}

@Suite("Automatic bilingual reader lifecycle") @MainActor
struct AutomaticReaderTests {
    private func longInput(_ count: Int = 64) -> BlockReaderInput {
        cleanupInput((0..<count).map { "English reporting paragraph \($0). A complete account of this event." })
    }

    @Test func longArticleAllCleanupBatchesSucceed() async {
        let directory = cleanupDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let spy = CleanupSpy()
        let current = controller(directory, spy: spy)
        await current.open(longInput())
        #expect(current.translatedCount == 64 && current.isComplete)
        #expect(await spy.cleanupCalls.map(\.count) == [12, 12, 12, 12, 12, 4])
    }

    @Test func middleCleanupFailureKeepsAll64BlocksAndLaterBatchesProceed() async {
        let directory = cleanupDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let spy = CleanupSpy(failAt: 3), input = longInput()
        let reader = controller(directory, spy: spy)
        await reader.open(input)
        #expect(reader.translatedCount == 64)
        #expect(reader.cleanupPending && reader.isComplete)
        #expect(await spy.cleanupCalls.count == 6)
        #expect(reader.prepared?.texts.map(\.blockID) == BlockReaderDocument(input: input).texts.map(\.blockID))
        #expect(reader.cleanupMessage?.contains("本地正文回退") == true)
        let oldCalls = await spy.translationCalls.count
        await reader.retryAICleanup()
        let cleanupCalls = await spy.cleanupCalls
        #expect(cleanupCalls.last == cleanupCalls[2])
        #expect(await spy.translationCalls.count == oldCalls)
        #expect(!reader.cleanupPending)
    }

    @Test func firstCleanupBatchFailureDoesNotLeave41TranslationsAtZero() async {
        let directory = cleanupDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let spy = CleanupSpy(failAt: 1)
        let current = controller(directory, spy: spy)
        await current.open(longInput(41))
        #expect(current.translatedCount == 41)
        #expect(await spy.cleanupCalls.count == 4)
    }

    @Test func everyCleanupResponseMalformedStillTranslatesLocalDocument() async {
        let directory = cleanupDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let spy = CleanupSpy()
        let reader = BlockReaderTranslationController(cache: .init(directory: directory.appendingPathComponent("translations")),
            transport: .init { blocks, _ in try await spy.translate(blocks) },
            cleanupTransport: .init { _, _, _ in "malformed" }, cleanupCache: .init(directory: directory.appendingPathComponent("cleanup")))
        await reader.open(longInput(41))
        #expect(reader.translatedCount == 41)
        #expect(reader.cleanupPending && reader.isComplete)
    }

    @Test func translationRetryDoesNotRepeatCleanupOrSuccessfulTranslations() async {
        let directory = cleanupDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let spy = CleanupSpy(failAt: 2, translationFailAt: 2)
        let current = controller(directory, spy: spy)
        await current.open(longInput())
        #expect(current.translatedCount == 12)
        let successful = Set(current.translatedHTML.keys)
        let cleanupCount = await spy.cleanupCalls.count
        await current.translate()
        #expect(current.translatedCount == 64)
        #expect(await spy.cleanupCalls.count == cleanupCount)
        #expect(await spy.translationCalls.dropFirst(2).flatMap { $0 }.allSatisfy { !successful.contains($0) })
    }

    @Test func reopenRetriesFailedCleanupWithoutTranslatingSuccessfulBlocksAgain() async {
        let directory = cleanupDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let spy = CleanupSpy(failAt: 2)
        await controller(directory, spy: spy).open(longInput())
        let translated = await spy.translationCalls.count
        let reopened = controller(directory, spy: spy)
        await reopened.open(longInput())
        #expect(reopened.translatedCount == 64)
        #expect(await spy.cleanupCalls.map(\.count) == [12, 12, 12, 12, 12, 4, 12])
        #expect(await spy.translationCalls.count == translated)
    }

    @Test func cleanupCacheWriteFailureDoesNotBlockTranslation() async {
        let directory = cleanupDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let spy = CleanupSpy()
        let reader = BlockReaderTranslationController(cache: .init(directory: directory),
            transport: .init { blocks, _ in try await spy.translate(blocks) },
            cleanupTransport: .init { batch, _, _ in try await spy.clean(batch) }, cleanupCache: .init(directory: nil))
        await reader.open(longInput(41))
        #expect(reader.translatedCount == 41)
        #expect(reader.cleanupMessage?.contains("暂未保存") == true)
    }

    @Test func cleanupByteBudgetSplitsUnicodeBlocks() {
        let candidates = (0..<20).map {
            ReaderAICleanup.Candidate(blockID: "id\($0)", kind: "paragraph", text: String(repeating: "文", count: 2_000))
        }
        let batches = ReaderAICleanup.batches(candidates)
        #expect(batches.count == 10)
        #expect(batches.allSatisfy { $0.reduce(0) { $0 + $1.text.utf8.count } <= 12_000 })
    }

    @Test func deterministicBaselineCacheRestoresIDsAndInvalidatesChangedContent() async throws {
        let directory = cleanupDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let first = await ReaderLocalDocumentCache(directory: directory).prepare(longInput())
        let second = await ReaderLocalDocumentCache(directory: directory).prepare(longInput())
        #expect(first.document == second.document)
        #expect(first.texts.map(\.blockID) == second.texts.map(\.blockID))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 1)
        let changed = await ReaderLocalDocumentCache(directory: directory).prepare(longInput(41))
        #expect(changed.document.documentHash != first.document.documentHash)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 2)
    }

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
        #expect(partial.translatedCount == 2)
        #expect(partial.isComplete)
        await partial.retryAICleanup()
        #expect(partial.isComplete)
        #expect(await spy.cleanupCalls.map(\.count) == [2, 1])
        #expect(await spy.translationCalls.map(\.count) == [2])
    }

    @Test func laterCleanupFailurePersistsEarlierDecisionsForReopen() async {
        let directory = cleanupDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let spy = CleanupSpy(failAt: 2), input = cleanupInput((0..<40).map { "English paragraph \($0)" })
        let first = controller(directory, spy: spy)
        await first.open(input)
        #expect(first.cleanupPending)
        #expect(first.prepared?.nodes.count == 40)
        #expect(first.translatedCount == 40)
        let second = controller(directory, spy: spy)
        await second.open(input)
        #expect(second.isComplete)
        #expect(await spy.cleanupCalls.map(\.count) == [12, 12, 12, 4, 12])
    }

    @Test func failedCleanupShowsOriginalAndOffersRetry() async {
        let directory = cleanupDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let spy = CleanupSpy(failAt: 1)
        let failing = controller(directory, spy: spy)
        await failing.open(cleanupInput())
        #expect(failing.prepared?.nodes.count == 2)
        #expect(failing.cleanupPending && !failing.isCleaning)
        #expect(failing.cleanupMessage != nil)
        #expect(failing.translatedCount == 2)
        await failing.retryAICleanup()
        #expect(failing.isComplete)
    }

    @Test func classifierCannotHideEntireStory() async {
        let directory = cleanupDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let reader = BlockReaderTranslationController(cache: .init(directory: directory),
            transport: .init { blocks, _ in
                String(decoding: try JSONSerialization.data(withJSONObject: ["translations": blocks.map {
                    ["blockID": $0.blockID, "translatedText": "有效译文"]
                }]), as: UTF8.self)
            },
            cleanupTransport: .init { batch, _, _ in try cleanupResponse(batch.map { ($0.blockID, "hide") }) },
            cleanupCache: .init(directory: directory.appendingPathComponent("cleanup")))
        await reader.open(cleanupInput())
        #expect(reader.prepared?.nodes.count == 2)
        #expect(reader.cleanupPending)
        #expect(reader.translatedCount == 2)
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
        #expect(await spy.cleanupCalls.count == 2)
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
