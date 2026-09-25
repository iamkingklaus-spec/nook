import Foundation
import Observation

public enum BlockReaderMode: String, CaseIterable, Identifiable, Sendable {
    case english, bilingual, chinese
    public var id: String { rawValue }
    public var label: String {
        switch self { case .english: "EN"; case .bilingual: "双语"; case .chinese: "中文" }
    }
}

/// Loading and mode changes never invoke the transport. Only the explicit
/// Translate action may send text. Responses are bound to a document generation.
@MainActor @Observable
public final class BlockReaderTranslationController {
    public var mode: BlockReaderMode = .english
    public private(set) var input: BlockReaderInput?
    public private(set) var isLoading = false
    public private(set) var isTranslating = false
    public private(set) var message: String?
    public private(set) var translatedCount = 0
    public var totalCount: Int { prepared?.texts.count ?? 0 }
    public var isComplete: Bool { prepared != nil && translatedCount == totalCount }
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
    var presentationTranslations: [String: String] { translations }
    @ObservationIgnored private var translations: [String: String] = [:]
    @ObservationIgnored private var key: BlockTranslationCacheKey?
    @ObservationIgnored private var model: GeminiTranslator.Model = .flashLite
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private let cache: BlockTranslationCache
    @ObservationIgnored private let transport: BlockTranslationTransport

    public convenience init() { self.init(cache: .shared, transport: .gemini) }

    init(cache: BlockTranslationCache, transport: BlockTranslationTransport) {
        self.cache = cache
        self.transport = transport
    }

    public func load(_ input: BlockReaderInput?, model: GeminiTranslator.Model = .flashLite) async {
        guard self.input != input || self.model != model || prepared == nil else { return }
        cancel()
        let token = generation
        self.input = input
        self.model = model
        prepared = nil
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
        let task = Task { await run(document: prepared, key: key, model: model, token: token) }
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
    }

    public func reset() {
        cancel()
        input = nil
        prepared = nil
        translatedHTML = [:]
        translations = [:]
        translatedCount = 0
        isLoading = false
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
                let validated = try BlockTranslationProtocol.validate(response, expected: batch)
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
