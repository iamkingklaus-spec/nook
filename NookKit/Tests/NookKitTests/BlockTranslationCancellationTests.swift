import Foundation
import Testing
@testable import NookKit

private func lifecycleInput(_ count: Int = 17) -> BlockReaderInput {
    .init(articleID: "lifecycle", url: URL(string: "https://example.org/lifecycle")!, html: nil,
          paragraphs: (0..<count).map { "Article paragraph \($0)." }, source: .rssFullContent)
}

private func reply(_ blocks: [BlockTranslationText]) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: ["translations": blocks.map {
        ["blockID": $0.blockID, "translatedText": "译文 " + $0.template]
    }]), as: UTF8.self)
}

private actor CancellableRequests {
    var calls: [[String]] = []
    var cancelled = false
    var waiting = false
    var waiters: [CheckedContinuation<Void, Never>] = []
    let suspendCall: Int?
    init(suspendCall: Int? = nil) { self.suspendCall = suspendCall }
    func request(_ blocks: [BlockTranslationText]) async throws -> String {
        calls.append(blocks.map(\.blockID))
        if calls.count == suspendCall {
            waiting = true
            waiters.forEach { $0.resume() }; waiters.removeAll()
            do { try await Task.sleep(for: .seconds(30)) }
            catch { cancelled = true; throw error }
        }
        return try reply(blocks)
    }
    func waitForRequest() async {
        if waiting { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    var transport: BlockTranslationTransport {
        .init { blocks, _ in try await self.request(blocks) }
    }
}

@Suite("Block translation durable partials and cancellation") @MainActor
struct BlockTranslationCancellationTests {
    @Test func fourteenOfSeventeenPersistedBlocksResumeOnlyThree() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fourteen-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = lifecycleInput(), document = BlockReaderDocument(input: lifecycleInput())
        let key = BlockTranslationCacheKey(input: input, document: document.document, model: .flashLite)
        let cache = BlockTranslationCache(directory: directory)
        // Simulate two previously committed successful batches and a restart.
        var saved: [String: String] = [:]
        for chunk in [Array(document.texts.prefix(7)), Array(document.texts.dropFirst(7).prefix(7))] {
            saved.merge(try BlockTranslationProtocol.validate(reply(chunk), expected: chunk)) { _, new in new }
            try await cache.store(saved, key: key)
        }
        let spy = CancellableRequests()
        let reopened = BlockReaderTranslationController(cache: BlockTranslationCache(directory: directory), transport: await spy.transport)
        await reopened.load(input)
        #expect(reopened.translatedCount == 14)
        #expect(reopened.diagnostics.cachedBlockCount == 14)
        await reopened.translate()
        #expect(reopened.isComplete)
        #expect(await spy.calls == [Array(document.texts.suffix(3)).map(\.blockID)])
        #expect(reopened.diagnostics.sentBlockCount == 3)
    }

    @Test func leavingReaderCancelsInFlightAndPreservesSuccessfulBatch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("leave-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = lifecycleInput(29), doc = BlockReaderDocument(input: lifecycleInput(29))
        let spy = CancellableRequests(suspendCall: 2)
        let controller = BlockReaderTranslationController(cache: BlockTranslationCache(directory: directory), transport: await spy.transport)
        await controller.load(input)
        let work = Task { await controller.translate() }
        await spy.waitForRequest()
        #expect(controller.translatedCount == 12)
        // The Reader's onDisappear uses precisely this reset path.
        controller.reset()
        await work.value
        #expect(await spy.cancelled)
        #expect(await spy.calls.count == 2) // The unsent third batch was cancelled too.
        let resumedSpy = CancellableRequests()
        let reopened = BlockReaderTranslationController(cache: BlockTranslationCache(directory: directory), transport: await resumedSpy.transport)
        await reopened.load(input)
        #expect(reopened.translatedCount == 12)
        await reopened.translate()
        #expect(reopened.isComplete)
        #expect(await resumedSpy.calls.flatMap { $0 } == Array(doc.texts.dropFirst(12)).map(\.blockID))
    }

    @Test func cancellingCallerPropagatesToTransportWithoutReset() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("caller-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let spy = CancellableRequests(suspendCall: 1)
        let controller = BlockReaderTranslationController(cache: BlockTranslationCache(directory: directory), transport: await spy.transport)
        await controller.load(lifecycleInput())
        let work = Task { await controller.translate() }
        await spy.waitForRequest()
        work.cancel()
        await work.value
        #expect(await spy.cancelled)
        #expect(await spy.calls.count == 1)
        #expect(!controller.isTranslating && controller.translatedCount == 0)
        #expect(controller.message == nil)
        await controller.translate()
        #expect(controller.isComplete)
    }

    @Test func completedBatchIsDurableBeforeTheNextBatchFinishes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("partial-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = lifecycleInput(), doc = BlockReaderDocument(input: lifecycleInput())
        let spy = CancellableRequests(suspendCall: 2)
        let controller = BlockReaderTranslationController(cache: BlockTranslationCache(directory: directory), transport: await spy.transport)
        await controller.load(input)
        let work = Task { await controller.translate() }
        await spy.waitForRequest()
        let loaded = await BlockTranslationCache(directory: directory).load(
            BlockTranslationCacheKey(input: input, document: doc.document, model: .flashLite), texts: doc.texts)
        #expect(loaded.count == 12)
        controller.cancel()
        await work.value
        #expect(controller.translatedCount == 12)
        #expect(await spy.cancelled)
        await controller.translate()
        #expect(controller.isComplete)
        let requests = await spy.calls
        #expect(requests[2] == Array(doc.texts.suffix(5)).map(\.blockID))
    }

    @Test func filteredMetadataNeverReachesRequestAndCacheSkipsAllSuccesses() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("eligible-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = BlockReaderInput(articleID: "eligible", url: URL(string: "https://example.org/eligible")!,
            html: "<p>Real news.</p><p>Photograph: Jane Doe/AP</p><p>Advertisement</p><p>https://example.org/</p><pre><code>print(1)</code></pre>",
            paragraphs: [], source: .rssFullContent)
        let spy = CancellableRequests()
        let first = BlockReaderTranslationController(cache: BlockTranslationCache(directory: directory), transport: await spy.transport)
        await first.load(input)
        #expect(first.totalCount == 1)
        await first.translate()
        let reopened = BlockReaderTranslationController(cache: BlockTranslationCache(directory: directory), transport: await spy.transport)
        await reopened.load(input)
        await reopened.translate()
        #expect(await spy.calls.count == 1)
        #expect(reopened.diagnostics.cachedBlockCount == 1 && reopened.diagnostics.sentBlockCount == 0)
    }
}
