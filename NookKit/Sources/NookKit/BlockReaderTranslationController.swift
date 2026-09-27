import Foundation
import Observation

public enum BlockReaderMode: String, CaseIterable, Identifiable, Sendable {
    case english, bilingual, chinese
    public var id: String { rawValue }
    public var label: String {
        switch self { case .english: "EN"; case .bilingual: "双语"; case .chinese: "中文" }
    }
}

/// `open` is the iOS Reader entry point: cleanup then translation, cache first.
/// `load` and mode changes remain local. Responses belong to one generation.
@MainActor @Observable
public final class BlockReaderTranslationController {
    public var mode: BlockReaderMode = .english
    public private(set) var input: BlockReaderInput?
    public private(set) var isLoading = false
    public private(set) var isTranslating = false
    public private(set) var isCleaning = false
    public private(set) var automaticPreparation = false
    public private(set) var cleanupPending = false
    public private(set) var message: String?
    public private(set) var translatedCount = 0
    public var totalCount: Int { prepared?.texts.count ?? 0 }
    public var isComplete: Bool { prepared != nil && !cleanupPending && translatedCount == totalCount }
    public var isPrepared: Bool { prepared != nil }
    private(set) var prepared: BlockReaderDocument?
    private(set) var translatedHTML: [String: String] = [:]
    private(set) var diagnostics = Diagnostics()
    struct Diagnostics {
        var candidateBlockCount = 0
        var filteredNoiseCount = 0
        var translatableBlockCount = 0
        var cachedBlockCount = 0
        var sentBlockCount = 0
    }
    /// Read-only validated templates for paragraph presentation inside legacy
    /// composite blocks. Does not change cache identity or initiate translation.
    var presentationTranslations: [String: String] {
        let visible = Set(prepared?.texts.map(\.blockID) ?? [])
        return translations.filter { visible.contains($0.key) }
    }
    @ObservationIgnored private var translations: [String: String] = [:]
    @ObservationIgnored private var key: BlockTranslationCacheKey?
    @ObservationIgnored private var model: GeminiTranslator.Model = .flashLite
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private let cache: BlockTranslationCache
    @ObservationIgnored private let transport: BlockTranslationTransport
    @ObservationIgnored private let cleanupTransport: ReaderCleanupTransport?
    @ObservationIgnored private let cleanupCache: ReaderCleanupCache
    @ObservationIgnored private var originalDocument: BlockReaderDocument?

    public convenience init() { self.init(cache: .shared, transport: .gemini, cleanupTransport: .gemini) }

    init(cache: BlockTranslationCache, transport: BlockTranslationTransport,
         cleanupTransport: ReaderCleanupTransport? = nil, cleanupCache: ReaderCleanupCache = .shared) {
        self.cache = cache
        self.transport = transport
        self.cleanupTransport = cleanupTransport
        self.cleanupCache = cleanupCache
    }

    /// Called only by the visible Reader task, never feed refresh/preloading.
    public func open(_ input: BlockReaderInput?, model: GeminiTranslator.Model = .flashLite) async {
        let changed = self.input != input || self.model != model || prepared == nil
        let firstAutomaticOpen = !automaticPreparation
        automaticPreparation = true
        if changed || firstAutomaticOpen { mode = .bilingual }
        await load(input, model: model)
        guard !Task.isCancelled, self.input == input, self.model == model else { return }
        if changed || firstAutomaticOpen { cleanupPending = cleanupTransport != nil && prepared != nil }
        await translate()
    }

    public func load(_ input: BlockReaderInput?, model: GeminiTranslator.Model = .flashLite) async {
        guard self.input != input || self.model != model || prepared == nil else { return }
        cancel()
        let token = generation
        self.input = input
        self.model = model
        prepared = nil
        originalDocument = nil
        cleanupPending = false
        key = nil
        translations = [:]
        translatedHTML = [:]
        translatedCount = 0
        diagnostics = Diagnostics()
        message = nil
        isLoading = input != nil
        guard let input else { return }
        let document = await Task.detached(priority: .userInitiated) { BlockReaderDocument(input: input) }.value
        guard generation == token, !Task.isCancelled else { return }
        let key = BlockTranslationCacheKey(input: input, document: document.document, model: model)
        let cached = await cache.load(key, texts: document.texts)
        guard generation == token, !Task.isCancelled else { return }
        prepared = document
        originalDocument = document
        self.key = key
        apply(cached, document: document)
        diagnostics = Diagnostics(candidateBlockCount: document.eligibility.count + document.preparationReasons.count,
            filteredNoiseCount: document.preparationReasons.count, translatableBlockCount: document.texts.count,
            cachedBlockCount: cached.count)
        logDiagnostics()
        isLoading = false
    }

    public func translate() async {
        guard !Task.isCancelled else { return }
        guard !isTranslating, !isLoading, !isComplete,
              let prepared, let key else { return }
        isTranslating = true
        message = nil
        let token = generation
        let model = model
        let task = Task {
            if automaticPreparation, cleanupTransport != nil {
                await cleanAndTranslate(key: key, model: model, token: token)
            } else {
                await run(document: prepared, key: key, model: model, token: token)
            }
        }
        work = task
        // The UI's explicit reset cancels this task, and cancellation of its
        // caller must reach URLSession too rather than leave unstructured work.
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    public func cancel() {
        generation = UUID()
        work?.cancel()
        work = nil
        isTranslating = false
        isCleaning = false
    }

    public func reset() {
        cancel()
        input = nil
        prepared = nil
        originalDocument = nil
        cleanupPending = false
        translatedHTML = [:]
        translations = [:]
        translatedCount = 0
        isLoading = false
    }

    private func cleanAndTranslate(key: BlockTranslationCacheKey, model: GeminiTranslator.Model, token: UUID) async {
        guard let originalDocument, let cleanupTransport else { return }
        isCleaning = true
        defer { if generation == token { isCleaning = false; isTranslating = false } }
        let candidates = ReaderAICleanup.candidates(originalDocument)
        let identity = ReaderCleanupCache.identity(key, candidates: candidates)
        var decisions = await cleanupCache.load(identity)
        do {
            try Task.checkCancellation()
            guard generation == token else { return }
            let expectedIDs = Set(candidates.map(\.blockID))
            decisions = decisions.filter { expectedIDs.contains($0.key) }
            if !originalDocument.texts.isEmpty && originalDocument.texts.allSatisfy({ decisions[$0.blockID] == .hide }) {
                decisions = [:] // Corrupt/old cache must not blank out the reader.
            }
            // Original neighborhoods, including already cached neighbors, matter
            // for author portraits/related cards during a partial retry.
            for batch in ReaderAICleanup.batches(candidates) {
                let missing = batch.filter { decisions[$0.blockID] == nil }
                if missing.isEmpty { continue }
                guard missing.allSatisfy({ $0.text.utf8.count <= 48_000 }) else { throw BlockTranslationError.tooLarge }
                try Task.checkCancellation()
                guard generation == token else { return }
                let response = try await cleanupTransport.request(missing, candidates, model)
                try Task.checkCancellation()
                guard generation == token else { return }
                let validated = try ReaderAICleanup.decode(response, expected: missing)
                let merged = decisions.merging(validated) { _, new in new }
                // A classifier must not blank out an entire news story.
                if !originalDocument.texts.isEmpty && originalDocument.texts.allSatisfy({ merged[$0.blockID] == .hide }) {
                    throw BlockTranslationError.malformed
                }
                decisions = merged
                try await cleanupCache.store(decisions, identity: identity)
            }
            try Task.checkCancellation()
            guard generation == token else { return }
            cleanupPending = candidates.contains { decisions[$0.blockID] == nil }
            let cleaned = ReaderAICleanup.filtered(originalDocument, decisions: decisions)
            prepared = cleaned
            apply(translations, document: cleaned)
            isCleaning = false
            if cleanupPending { message = "部分内容尚未完成清洗，已保留原文；可重试清洗与翻译。" }
            await run(document: cleaned, key: key, model: model, token: token)
        } catch {
            guard generation == token, !Task.isCancelled else { return }
            cleanupPending = true
            // No successful source text is destroyed on a failed cleanup. A
            // later explicit retry resumes cached decisions and translations.
            prepared = originalDocument
            apply(translations, document: originalDocument)
            if let failure = error as? GeminiTranslator.Failure, case .missingCredential = failure.kind {
                message = "请先在设置中配置 Gemini API Key；当前显示原文。"
            } else {
                message = "Gemini 清洗未完成，当前保留原文；可重试清洗与翻译。"
            }
        }
    }

    private func run(document: BlockReaderDocument, key: BlockTranslationCacheKey,
                     model: GeminiTranslator.Model, token: UUID) async {
        defer { if generation == token { isTranslating = false } }
        do {
            let missing = document.texts.filter { translations[$0.blockID] == nil }
            for batch in try BlockTranslationProtocol.batches(missing) {
                try Task.checkCancellation()
                guard generation == token else { return }
                diagnostics.sentBlockCount += batch.count
                logDiagnostics()
                let response = try await transport.request(batch, model)
                try Task.checkCancellation()
                guard generation == token else { return }
                let validated = (try? BlockTranslationProtocol.salvage(response, expected: batch)) ?? [:]
                if validated.count != batch.count {
                    message = "部分翻译失败；已保存成功段落，可重试未完成的段落。"
                }
                let merged = translations.merging(validated) { _, new in new }
                apply(merged, document: document)
                do { try await cache.store(merged, key: key) }
                catch {
                    if generation == token { message = "译文已显示，但本地缓存写入失败；再次打开可能需要重新翻译。" }
                }
            }
        } catch is CancellationError {
            // Switching article/content cancels the old generation silently.
        } catch {
            guard !Task.isCancelled else { return }
            guard generation == token else { return }
            if let failure = error as? GeminiTranslator.Failure {
                switch failure.kind {
                case .missingCredential: message = "请先在设置中配置 Gemini API Key。"
                default: message = "Gemini 翻译未完成（\(failure.finishReason ?? String(describing: failure.kind))）。可重试未完成的段落。"
                }
            } else {
                message = error.localizedDescription
            }
        }
    }

    private func logDiagnostics() {
        #if DEBUG
        print("[BlockReader] candidate=\(diagnostics.candidateBlockCount) filtered=\(diagnostics.filteredNoiseCount) translatable=\(diagnostics.translatableBlockCount) cached=\(diagnostics.cachedBlockCount) sent=\(diagnostics.sentBlockCount)")
        #endif
    }

    private func apply(_ values: [String: String], document: BlockReaderDocument) {
        translations = values
        translatedHTML = Dictionary(uniqueKeysWithValues: document.texts.compactMap { text in
            guard let value = values[text.blockID], let html = try? text.restore(value) else { return nil }
            return (text.blockID, html)
        })
        translatedCount = translatedHTML.count
    }
}
