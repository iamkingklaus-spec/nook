import Foundation
import Observation

/// Separate from ReaderStore: diagnostics cannot mutate subscriptions, article
/// state, refresh timestamps, extraction caches or translation caches.
@MainActor @Observable
public final class FeedHealthDiagnostics {
    public static let shared = FeedHealthDiagnostics()
    public private(set) var reports: [URL: FeedHealthReport] = [:]
    public private(set) var samplingURL: URL?
    private var fetching: Set<URL> = []
    @ObservationIgnored private var snapshots: [URL: FeedHealthSnapshot] = [:]
    @ObservationIgnored private let fetch: @Sendable (URL) async -> FeedHealthSnapshot
    @ObservationIgnored private let sample: @MainActor (Article) async -> FeedExtractionSample
    @ObservationIgnored private let now: () -> Date

    public convenience init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 25
        let service = RSSFeedService(session: URLSession(configuration: config))
        self.init(fetch: { await service.inspectFeed(url: $0) }, sample: Self.liveSample)
    }

    init(fetch: @escaping @Sendable (URL) async -> FeedHealthSnapshot,
         sample: @escaping @MainActor (Article) async -> FeedExtractionSample,
         now: @escaping () -> Date = Date.init) {
        self.fetch = fetch
        self.sample = sample
        self.now = now
    }

    public func isBusy(_ url: URL) -> Bool { fetching.contains(url) || samplingURL == url }

    public func testFeed(_ url: URL, force: Bool = false) async {
        guard !isBusy(url) else { return }
        fetching.insert(url)
        defer { fetching.remove(url) }
        let snapshot = await load(url, force: force)
        if !Task.isCancelled { publish(snapshot) }
    }

    public func testArticleExtraction(_ url: URL, force: Bool = false) async {
        // One sampler globally, one article at a time. Never a fan-out of HEADs.
        guard !isBusy(url), samplingURL == nil else { return }
        samplingURL = url
        defer { samplingURL = nil }
        var snapshot = await load(url, force: false)
        guard !Task.isCancelled else { return }
        publish(snapshot)
        guard snapshot.report.canSample else { return }
        if !force, let checked = snapshot.report.extractionCheckedAt, now().timeIntervalSince(checked) < 300 { return }
        var results: [FeedExtractionSample] = []
        for article in Self.recentUniqueArticles(snapshot.articles) {
            if Task.isCancelled { return }
            results.append(await sample(article))
        }
        guard !Task.isCancelled else { return }
        snapshot.report.extractionSamples = results
        snapshot.report.extractionCheckedAt = now()
        publish(snapshot)
    }

    private func load(_ url: URL, force: Bool) async -> FeedHealthSnapshot {
        if !force, let cached = snapshots[url] {
            let ttl: TimeInterval = cached.report.parseResult == .success ? 300 : 30
            let age = now().timeIntervalSince(cached.report.checkedAt)
            if age >= 0 && age < ttl { return cached }
        }
        return await fetch(url)
    }

    private func publish(_ snapshot: FeedHealthSnapshot) {
        let url = snapshot.report.requestedURL
        reports[url] = snapshot.report
        var bounded = snapshot
        bounded.articles = Self.recentUniqueArticles(snapshot.articles)
        snapshots[url] = bounded
        if snapshots.count > 32,
           let oldest = snapshots.filter({ !isBusy($0.key) }).min(by: { $0.value.report.checkedAt < $1.value.report.checkedAt })?.key {
            snapshots[oldest] = nil
            reports[oldest] = nil
        }
    }

    static func recentUniqueArticles(_ articles: [Article]) -> [Article] {
        var seen: Set<URL> = []
        return Array(articles.sorted { $0.publishedAt > $1.publishedAt }
            .filter { seen.insert($0.url).inserted }.prefix(3))
    }

    static func liveSample(_ article: Article) async -> FeedExtractionSample {
        let extractor = ReaderModeExtractor()
        return await sampleArticle(article) { engine in
            await extractor.extract(url: article.url, engine: engine, timeout: 12)
        }
    }

    /// Injectable parser boundary; production and regression tests exercise the
    /// same RSS-first selection and quality pipeline as the Reader.
    static func sampleArticle(_ article: Article,
                              extract: (ReaderParserEngine) async -> ReaderModeExtractor.Outcome) async -> FeedExtractionSample {
        var errors: [String] = []
        let result = await ReaderContentResolver.resolve(article: article, preferred: .preferred) { engine in
            let outcome = await extract(engine)
            switch outcome {
            case .failed: errors.append("\(engine.label): 提取失败")
            case .timedOut: errors.append("\(engine.label): 请求超时")
            case .gone: errors.append("\(engine.label): 原文已不存在")
            case .success: break
            }
            return outcome
        }
        let quality = result.candidate?.assessment.quality ?? .unavailable
        return .init(articleURL: article.url, quality: quality,
                     errorReason: quality == .fullCandidate || errors.isEmpty ? nil : errors.joined(separator: "; "))
    }
}
