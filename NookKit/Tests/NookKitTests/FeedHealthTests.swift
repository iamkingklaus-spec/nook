import Foundation
import Testing
@testable import NookKit

private func healthRSS(_ items: String = "") -> String {
    "<rss version='2.0'><channel><title>News</title><link>https://example.com/news/</link><description>News feed</description>\(items)</channel></rss>"
}
private func healthItem(_ link: String = "/story", extra: String = "<description>A standfirst.</description>") -> String {
    "<item><title>Story</title>\(link.isEmpty ? "" : "<link>\(link)</link>")\(extra)</item>"
}

/// Per-test handlers are keyed by a unique host; no shared mutable mock handler
/// races when Swift Testing runs suites concurrently.
private final class HealthRequests: @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    private let lock = NSLock()
    private var handlers: [String: Handler] = [:]
    private var counts: [String: Int] = [:]
    func install(_ host: String, handler: @escaping Handler) { lock.withLock { handlers[host] = handler; counts[host] = 0 } }
    func remove(_ host: String) { lock.withLock { handlers[host] = nil; counts[host] = nil } }
    func count(_ host: String) -> Int { lock.withLock { counts[host] ?? 0 } }
    func response(_ request: URLRequest) throws -> (HTTPURLResponse, Data) {
        let handler = lock.withLock {
            let host = request.url!.host!
            counts[host, default: 0] += 1
            return handlers[host]
        }
        guard let handler else { throw URLError(.badServerResponse) }
        return try handler(request)
    }
}
private final class HealthURLProtocol: URLProtocol {
    static let requests = HealthRequests()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (response, data) = try Self.requests.response(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
private struct HealthNetwork {
    let url: URL
    let service: RSSFeedService
    let session: URLSession
    var count: Int { HealthURLProtocol.requests.count(url.host!) }
    init(body: String, status: Int = 200, finalPath: String? = nil,
         mime: String = "application/rss+xml", error: URLError.Code? = nil) {
        let host = "\(UUID().uuidString.lowercased()).example.com"
        url = URL(string: "https://\(host)/feed.xml")!
        HealthURLProtocol.requests.install(host) { request in
            if let error { throw URLError(error) }
            let final = finalPath.map { URL(string: "https://\(host)\($0)")! } ?? request.url!
            return (HTTPURLResponse(url: final, statusCode: status, httpVersion: nil,
                                    headerFields: ["Content-Type": mime])!, Data(body.utf8))
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HealthURLProtocol.self]
        session = URLSession(configuration: config)
        service = RSSFeedService(session: session)
    }
    func close() { session.invalidateAndCancel(); HealthURLProtocol.requests.remove(url.host!) }
    func inspect() async -> FeedHealthSnapshot { await service.inspectFeed(url: url) }
}

@Suite("Feed Health strict requests")
struct FeedHealthRequestTests {
    @Test func normalRSS() async {
        let net = HealthNetwork(body: healthRSS(healthItem())); defer { net.close() }
        let result = await net.inspect()
        #expect(result.report.parseResult == .success)
        #expect(result.report.format == .rss)
        #expect(result.report.itemCount == 1)
        #expect(result.report.validArticleURLCount == 1)
        #expect(result.report.severity == .normal)
        #expect(result.report.extractionSamples == nil)
        #expect(net.count == 1) // no article HEAD/GET during basic detection
    }
    @Test func normalAtom() async {
        let xml = "<feed xmlns='http://www.w3.org/2005/Atom'><title>News</title><entry><id>one</id><title>First</title><link href='/one'/><summary>Brief</summary></entry></feed>"
        let net = HealthNetwork(body: xml); defer { net.close() }
        let result = await net.inspect()
        #expect(result.report.format == .atom)
        #expect(result.report.validArticleURLCount == 1)
        #expect(result.report.parseResult == .success)
    }
    @Test func finalRedirectURLIsRetainedAndUsedForRelativeLinks() async {
        // URLSession hands the service the final response, not the redirect's 302.
        let net = HealthNetwork(body: healthRSS(healthItem("article")), finalPath: "/moved/feed.xml")
        defer { net.close() }
        let result = await net.inspect()
        #expect(result.report.requestedURL == net.url)
        #expect(result.report.finalURL?.path == "/moved/feed.xml")
        #expect(result.report.httpStatus == 200)
        #expect(result.articles.first?.url.path == "/moved/article")
    }
    @Test func HTTPErrorIsNotParseFailure() async {
        let net = HealthNetwork(body: "Unavailable", status: 503); defer { net.close() }
        let report = await net.inspect().report
        #expect(report.httpStatus == 503)
        #expect(report.parseResult == .notTested)
        #expect(report.errorReason == "HTTP 503")
        #expect(report.severity == .failure)
    }
    @Test func offlineIsTransientRequestFailure() async {
        let net = HealthNetwork(body: "", error: .notConnectedToInternet); defer { net.close() }
        let report = await net.inspect().report
        #expect(report.httpStatus == nil)
        #expect(report.parseResult == .notTested)
        #expect(report.errorReason != nil)
        #expect(report.severity == .failure)
    }
    @Test func malformedXML() async {
        let net = HealthNetwork(body: "<rss><channel><item></channel>"); defer { net.close() }
        let report = await net.inspect().report
        #expect(report.parseResult == .malformedXML)
        #expect(report.severity == .failure)
    }
    @Test func validEmptyRSSIsHealthy() async {
        let net = HealthNetwork(body: healthRSS()); defer { net.close() }
        let report = await net.inspect().report
        #expect(report.parseResult == .success)
        #expect(report.itemCount == 0)
        #expect(report.feedDescription == "Feed 正常，目前没有文章。")
        #expect(report.severity == .normal)
        #expect(!report.canSample)
        #expect(net.count == 1)
    }
    @Test func validEmptyAtomIsHealthy() async {
        let net = HealthNetwork(body: "<feed xmlns='http://www.w3.org/2005/Atom'><title>Empty</title></feed>")
        defer { net.close() }
        let report = await net.inspect().report
        #expect(report.parseResult == .success)
        #expect(report.itemCount == 0)
        #expect(report.severity == .normal)
    }
    @Test func webpageAdvertisedFeedIsNotFetchedOrReportedHealthy() async {
        let net = HealthNetwork(body: "<html><head><link rel='alternate' type='application/rss+xml' href='/actual.xml'/></head><body>News</body></html>", mime: "text/html")
        defer { net.close() }
        let report = await net.inspect().report
        #expect(report.parseResult == .webPage)
        #expect(report.discoveredFeedURLs.first?.path == "/actual.xml")
        #expect(report.finalURL == net.url)
        #expect(report.severity == .failure)
        #expect(net.count == 1)
    }
    @Test func malformedHTMLIsStillIdentifiedAsWebpage() async {
        let net = HealthNetwork(body: "<html><head><title>Website</title></head><body><br></body></html>", mime: "text/html")
        defer { net.close() }
        #expect(await net.inspect().report.parseResult == .webPage)
    }
    @Test func arbitraryXMLIsNotEmptyRSS() async {
        let net = HealthNetwork(body: "<document><title>Not RSS</title></document>"); defer { net.close() }
        #expect(await net.inspect().report.parseResult == .notFeed)
    }
    @Test func missingChannelIsNotHealthyEmptyRSS() async {
        let net = HealthNetwork(body: "<rss version='2.0'/>"); defer { net.close() }
        #expect(await net.inspect().report.parseResult == .notFeed)
    }
    @Test func missingAndInvalidArticleLinksAreCountedBeforeFallback() async {
        let net = HealthNetwork(body: healthRSS(healthItem("") + healthItem("javascript:alert(1)") + healthItem("/valid")))
        defer { net.close() }
        let result = await net.inspect()
        #expect(result.report.itemCount == 3)
        #expect(result.report.missingArticleURLCount == 1)
        #expect(result.report.invalidArticleURLCount == 1)
        #expect(result.report.validArticleURLCount == 1)
        #expect(result.report.invalidOrMissingArticleURLCount == 2)
        #expect(result.report.severity == .warning)
        #expect(result.articles.count == 1)
        #expect(net.count == 1)
    }
    @Test func homepageFallbackNeverCountsAsArticle() async {
        let net = HealthNetwork(body: healthRSS(healthItem("") + healthItem("https://example.com/news") + healthItem("/")))
        defer { net.close() }
        let result = await net.inspect()
        #expect(result.report.validArticleURLCount == 0)
        #expect(result.report.homepageFallbackCount == 2)
        #expect(result.report.missingArticleURLCount == 1)
        #expect(result.articles.isEmpty)
    }
    @Test func atomXMLBaseAndAlternateEvidenceSurvive() async {
        let xml = "<feed xmlns='http://www.w3.org/2005/Atom' xml:base='https://example.com/articles/'><entry><title>One</title><source><link href='https://example.com/'/></source><link rel='self' href='self.atom'/><link href='one'/></entry></feed>"
        let net = HealthNetwork(body: xml); defer { net.close() }
        let result = await net.inspect()
        #expect(result.report.articleLinks.first?.rawValue == "one")
        #expect(result.articles.first?.url.absoluteString == "https://example.com/articles/one")
    }
    @Test func titleFallbackIsNotEvidenceOfRSSSummary() async {
        let net = HealthNetwork(body: healthRSS(healthItem("/one", extra: ""))); defer { net.close() }
        #expect(await net.inspect().articles.first?.summary == "")
    }
    @Test func unsafeOrMalformedLinksAreNotHealthy() {
        let base = URL(string: "https://example.com/feed")!
        for raw in ["file:///private/file", "mailto:a@example.com", "https://one.comhttps://two.com", "bad link", "#top", "/bad%zz"] {
            #expect(FeedArticleLinkCheck.inspect(raw, baseURL: base, siteURL: base).status == .invalid)
        }
    }
    @Test func unsupportedFeedSchemeMakesNoNetworkRequest() async {
        let net = HealthNetwork(body: healthRSS()); defer { net.close() }
        let report = await net.service.inspectFeed(url: URL(string: "file:///feed.xml")!).report
        #expect(report.errorReason != nil)
        #expect(report.httpStatus == nil)
        #expect(net.count == 0)
    }
    @Test func legitimateHostsAndIPv6AreNotRejectedBySubstringHeuristics() {
        #expect(FeedArticleLinkCheck.isWebURL(URL(string: "https://httpwatch.example.com/feed")!))
        #expect(FeedArticleLinkCheck.isWebURL(URL(string: "http://[::1]/feed")!))
    }
}

private actor HealthCounter {
    var requests = 0
    let snapshot: FeedHealthSnapshot
    init(_ snapshot: FeedHealthSnapshot) { self.snapshot = snapshot }
    func fetch() async -> FeedHealthSnapshot {
        requests += 1
        await Task.yield()
        return snapshot
    }
}
@MainActor private final class HealthClock {
    var date = Date(timeIntervalSince1970: 1_700_000_000)
}

@Suite("Feed Health sampling and local cache") @MainActor
struct FeedHealthDiagnosticTests {
    private let url = URL(string: "https://example.com/feed")!
    private func snapshot(at date: Date = .now, count: Int = 1) -> FeedHealthSnapshot {
        var report = FeedHealthReport(requestedURL: url, checkedAt: date)
        report.parseResult = .success
        report.itemCount = count
        let articles = (0..<count).map { Fixture.article("article\($0)", feedID: "feed") }
        report.articleLinks = articles.map { .init(rawValue: $0.url.absoluteString, url: $0.url, status: .valid) }
        return .init(report: report, articles: articles)
    }
    @Test func extractionUsesRSSFullWithoutParserRequests() async {
        var article = Fixture.article("a", feedID: "f")
        article.sourceContents = [.init(source: .rssFullContent, content: "<p>The bridge reopened at noon.</p>", format: .html)]
        var calls = 0
        let result = await FeedHealthDiagnostics.sampleArticle(article) { _ in calls += 1; return .failed }
        #expect(result.quality == .fullCandidate)
        #expect(calls == 0)
    }
    @Test func extractionFallsBackToRSSSummary() async {
        var article = Fixture.article("a", feedID: "f"); article.summary = "Only a standfirst."
        var calls = 0
        let result = await FeedHealthDiagnostics.sampleArticle(article) { _ in calls += 1; return .failed }
        #expect(result.quality == .summaryOnly)
        #expect(result.errorReason != nil)
        #expect(calls == 2)
    }
    @Test func extractionUnavailableWhenNeitherParserNorRSSHasBody() async {
        let result = await FeedHealthDiagnostics.sampleArticle(Fixture.article("a", feedID: "f")) { _ in .failed }
        #expect(result.quality == .unavailable)
    }
    @Test func extractionCanBeUncertainWithoutBeingUnavailable() async {
        var article = Fixture.article("a", feedID: "f"); article.summary = "Only a standfirst."
        let result = await FeedHealthDiagnostics.sampleArticle(article) { engine in
            .success(.init(html: "<p>Only a standfirst.</p>", engine: engine))
        }
        #expect(result.quality == .possiblySummary)
    }
    @Test func oneSampleFailureDoesNotTurnHealthyFeedRed() async {
        let value = snapshot(count: 2)
        let diagnostics = FeedHealthDiagnostics(fetch: { _ in value }, sample: { article in
            .init(articleURL: article.url, quality: article.id == "article0" ? .fullCandidate : .unavailable)
        })
        await diagnostics.testArticleExtraction(url)
        #expect(diagnostics.reports[url]?.parseResult == .success)
        #expect(diagnostics.reports[url]?.severity == .warning)
        #expect(diagnostics.reports[url]?.extractionSamples?.count == 2)
        #expect(diagnostics.reports[url]?.extractionDescription.contains("仅代表") == true)
    }
    @Test func basicTestNeverSamplesArticles() async {
        let value = snapshot()
        var samples = 0
        let diagnostics = FeedHealthDiagnostics(fetch: { _ in value }, sample: { article in
            samples += 1; return .init(articleURL: article.url, quality: .fullCandidate)
        })
        await diagnostics.testFeed(url)
        #expect(samples == 0)
        #expect(diagnostics.reports[url]?.extractionSamples == nil)
        #expect(diagnostics.reports[url]?.extractionDescription == "正文未测试")
    }
    @Test func samplingIsCappedSequentialAndDeduplicated() async {
        var value = snapshot(count: 12)
        value.articles.append(value.articles[0])
        let input = value
        var active = 0, peak = 0
        var sampled: [URL] = []
        let diagnostics = FeedHealthDiagnostics(fetch: { _ in input }, sample: { article in
            active += 1; peak = max(peak, active); sampled.append(article.url)
            await Task.yield(); active -= 1
            return .init(articleURL: article.url, quality: .fullCandidate)
        })
        await diagnostics.testArticleExtraction(url)
        #expect(sampled.count == 3)
        #expect(Set(sampled).count == 3)
        #expect(peak == 1)
    }
    @Test func sampleSelectionUsesMostRecentArticles() {
        var articles = snapshot(count: 5).articles
        for index in articles.indices { articles[index].publishedAt = Date(timeIntervalSince1970: Double(index)) }
        #expect(FeedHealthDiagnostics.recentUniqueArticles(articles).map(\.id) == ["article4", "article3", "article2"])
    }
    @Test func repeatedFeedClicksUseLocalCacheAndRetryBypassesIt() async {
        let counter = HealthCounter(snapshot())
        let diagnostics = FeedHealthDiagnostics(fetch: { _ in await counter.fetch() }, sample: { .init(articleURL: $0.url, quality: .fullCandidate) })
        await diagnostics.testFeed(url)
        let checked = diagnostics.reports[url]?.checkedAt
        await diagnostics.testFeed(url)
        #expect(await counter.requests == 1)
        #expect(diagnostics.reports[url]?.checkedAt == checked)
        await diagnostics.testFeed(url, force: true)
        #expect(await counter.requests == 2)
    }
    @Test func concurrentClicksDoNotDuplicateRequests() async {
        let counter = HealthCounter(snapshot())
        let diagnostics = FeedHealthDiagnostics(fetch: { _ in await counter.fetch() }, sample: { .init(articleURL: $0.url, quality: .fullCandidate) })
        async let first: Void = diagnostics.testFeed(url)
        async let second: Void = diagnostics.testFeed(url)
        _ = await (first, second)
        #expect(await counter.requests == 1)
    }
    @Test func failureCacheExpiresQuickly() async {
        let clock = HealthClock()
        var value = snapshot(at: clock.date)
        value.report.parseResult = .notTested; value.report.errorReason = "Offline"
        let counter = HealthCounter(value)
        let diagnostics = FeedHealthDiagnostics(fetch: { _ in await counter.fetch() }, sample: { .init(articleURL: $0.url, quality: .fullCandidate) }, now: { clock.date })
        await diagnostics.testFeed(url)
        clock.date += 10
        await diagnostics.testFeed(url)
        #expect(await counter.requests == 1)
        clock.date += 21
        await diagnostics.testFeed(url)
        #expect(await counter.requests == 2)
    }
    @Test func successCacheExpiresAfterFiveMinutes() async {
        let clock = HealthClock()
        let counter = HealthCounter(snapshot(at: clock.date))
        let diagnostics = FeedHealthDiagnostics(fetch: { _ in await counter.fetch() }, sample: { .init(articleURL: $0.url, quality: .fullCandidate) }, now: { clock.date })
        await diagnostics.testFeed(url)
        clock.date += 301
        await diagnostics.testFeed(url)
        #expect(await counter.requests == 2)
    }
    @Test func repeatedSamplingUsesCacheAndExplicitRetryRerunsIt() async {
        let value = snapshot()
        var samples = 0
        let diagnostics = FeedHealthDiagnostics(fetch: { _ in value }, sample: { article in
            samples += 1; return .init(articleURL: article.url, quality: .fullCandidate)
        })
        await diagnostics.testArticleExtraction(url)
        await diagnostics.testArticleExtraction(url)
        #expect(samples == 1)
        #expect(diagnostics.reports[url]?.checkedAt == value.report.checkedAt)
        await diagnostics.testArticleExtraction(url, force: true)
        #expect(samples == 2)
    }
    @Test func newDiagnosticsInstanceHasNoPermanentBadFeedState() async {
        let value = snapshot()
        let first = FeedHealthDiagnostics(fetch: { _ in value }, sample: { .init(articleURL: $0.url, quality: .unavailable) })
        await first.testArticleExtraction(url)
        let second = FeedHealthDiagnostics(fetch: { _ in value }, sample: { .init(articleURL: $0.url, quality: .unavailable) })
        #expect(second.reports.isEmpty)
    }
    @Test func diagnosticsLeaveSubscriptionsReadStarredCategoriesAndRefreshUntouched() async throws {
        let net = HealthNetwork(body: healthRSS(healthItem())); defer { net.close() }
        var feed = Fixture.feed("user-feed", category: "My folder")
        feed.feedURL = net.url
        feed.lastFetchedAt = Date(timeIntervalSince1970: 123)
        var article = Fixture.article("saved", feedID: feed.id, isRead: true, isStarred: true)
        article.categories = ["custom"]
        let library = Fixture.library(feeds: [feed], articles: [article], folders: ["My folder"])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(library)
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = ReaderStorage(directoryURL: root)
        try storage.save(library)
        let loadedBefore = try #require(try storage.load())
        let savedBefore = try encoder.encode(loadedBefore)
        let service = net.service
        let diagnostics = FeedHealthDiagnostics(fetch: { await service.inspectFeed(url: $0) }, sample: { article in
            await FeedHealthDiagnostics.sampleArticle(article) { _ in .failed }
        })
        await diagnostics.testFeed(net.url)
        await diagnostics.testArticleExtraction(net.url)
        #expect(try encoder.encode(library) == before)
        let loadedAfter = try #require(try storage.load())
        #expect(try encoder.encode(loadedAfter) == savedBefore)
        #expect(library.articles[0].isRead && library.articles[0].isStarred)
        #expect(library.articles[0].categories == ["custom"])
        #expect(library.feeds[0].feedURL == net.url)
        #expect(library.feeds[0].lastFetchedAt == feed.lastFetchedAt)
        #expect(storage.loadReaderShards().isEmpty)
    }
}
