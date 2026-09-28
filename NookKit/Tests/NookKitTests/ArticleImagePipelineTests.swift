import Foundation
import Testing
@testable import NookKit

private actor ImageRequestSpy {
    var calls: [URL] = []
    let data: Data
    let failPaths: Set<String>
    init(_ data: Data, failPaths: Set<String> = []) { self.data = data; self.failPaths = failPaths }
    func fetch(_ url: URL) throws -> Data {
        calls.append(url)
        if failPaths.contains(url.path) { throw URLError(.badServerResponse) }
        return data
    }
}

@Suite("Unified article image pipeline")
struct ArticleImagePipelineTests {
    private let base = URL(string: "https://example.com/story")!
    private func candidate(_ path: String, _ source: ArticleImageCandidate.Source = .rssMedia,
                           _ width: Int? = nil, _ height: Int? = nil) -> ArticleImageCandidate {
        .init(url: URL(string: path, relativeTo: base)!.absoluteURL, source: source, width: width, height: height)
    }
    private func article() -> Article {
        var value = Fixture.article("story", feedID: "feed")
        value.rssImages = [.init(url: URL(string: "https://example.com/rss.jpg")!, provenance: .mediaThumbnail, width: 240, height: 135)]
        return value
    }
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("image-tests-\(UUID())") }

    @Test func rssDimensionsSurviveParsingAndContentRoundTrip() throws {
        let feed = try FeedXMLParser(feedURL: base).parse(data: Data(ArticleImageFixture.rss.utf8))
        let article = try #require(feed.articles.first)
        #expect(article.rssImages.map(\.width) == [240, 1600])
        let copy = try JSONDecoder().decode(ArticleContent.self, from: JSONEncoder().encode(ArticleContent(article))).makeArticle()
        #expect(copy.rssImages == article.rssImages)
        #expect(ArticleImagePolicy.ranked(ArticleImagePolicy.rssCandidates(copy)).first?.width == 1600)
    }
    @Test func oldImageMetadataDecodesWithoutDimensions() throws {
        let data = Data(#"{"url":"https://example.com/a.jpg","provenance":"mediaContent"}"#.utf8)
        let value = try JSONDecoder().decode(ArticleImageMetadata.self, from: data)
        #expect(value.width == nil && value.height == nil)
    }
    @Test func openGraphDimensionsAndSecureURL() {
        let values = ArticleImageHTML.candidates(ArticleImageFixture.page, baseURL: base)
        let og = values.filter { $0.source == .openGraph }
        #expect(og.count == 2)
        #expect(og.allSatisfy { $0.width == 1600 && $0.height == 900 })
        #expect(og.contains { $0.url.host == "cdn.example.com" })
    }
    @Test func multipleOGImagesKeepSeparateDimensions() {
        let values = ArticleImageHTML.candidates("""
        <meta property='og:image' content='/one.jpg'><meta property='og:image:width' content='1200'>
        <meta property='og:image' content='/two.jpg'><meta property='og:image:width' content='800'>
        """, baseURL: base)
        #expect(values.first { $0.url.path == "/one.jpg" }?.width == 1200)
        #expect(values.first { $0.url.path == "/two.jpg" }?.width == 800)
    }
    @Test func twitterImageIsCandidate() {
        #expect(ArticleImageHTML.candidates(ArticleImageFixture.page, baseURL: base).contains { $0.source == .twitterImage })
    }
    @Test func srcsetUsesExplicitLargestWidthAndKeepsURL() {
        let values = ArticleImageHTML.candidates(ArticleImageFixture.page, baseURL: base)
        let value = values.first { $0.url.path == "/lead-1800.jpg" }
        #expect(value?.source == .srcset && value?.width == 1800 && value?.height == 1200)
        #expect(!values.contains { $0.url.path == "/lead-2400.jpg" })
    }
    @Test func densitySrcsetWithAndWithoutBaseDimensions() {
        let values = ArticleImageHTML.candidates("""
        <article><img src='/a.jpg' width='600' height='400' srcset='/a2.jpg 2x'>
        <img src='/b.jpg' srcset='/b2.jpg 2x'></article>
        """, baseURL: base)
        #expect(values.first { $0.url.path == "/a2.jpg" }?.width == 1200)
        #expect(values.contains { $0.url.path == "/b2.jpg" && $0.width == nil })
    }
    @Test func articleLeadDoesNotUseFirstPageImage() {
        let values = ArticleImageHTML.candidates(ArticleImageFixture.page, baseURL: base)
        #expect(!values.contains { $0.url.path == "/logo.png" })
        #expect(values.first { $0.source == .articleLeadImage }?.url.path == "/lead.jpg")
    }
    @Test func structuralAvatarAndAsideExcluded() {
        let paths = ArticleImageHTML.candidates(ArticleImageFixture.page, baseURL: base).map(\.url.path)
        #expect(!paths.contains("/portrait.jpg") && !paths.contains("/promo.jpg"))
    }
    @Test func thumbnailLosesToLargeOG() {
        let values = ArticleImagePolicy.ranked([candidate("/thumb.jpg", .rssThumbnail, 240, 135), candidate("/og.jpg", .openGraph, 1600, 900)])
        #expect(values.first?.source == .openGraph)
    }
    @Test func equalQualityRankingIsDeterministic() {
        let rss = candidate("/rss.jpg", .rssMedia, 1600, 900), og = candidate("/og.jpg", .openGraph, 1600, 900)
        #expect(ArticleImagePolicy.ranked([rss, og]) == ArticleImagePolicy.ranked([og, rss]))
        #expect(ArticleImagePolicy.ranked([rss, og]).first == rss)
    }
    @Test func filenameAloneDoesNotRemoveNewsPhoto() {
        #expect(ArticleImagePolicy.acceptable(candidate("/company-logo-protest.jpg", .openGraph, 1600, 900)))
        #expect(!ArticleImagePolicy.acceptable(candidate("/logo.png", .openGraph, 180, 180)))
    }
    @Test func trackingAndUnsafeURLsAreRejected() {
        #expect(!ArticleImagePolicy.acceptable(candidate("/pixel.gif", .rssMedia, 1, 1)))
        #expect(!ArticleImagePolicy.acceptable(.init(url: URL(string: "file:///tmp/photo.jpg")!, source: .openGraph)))
    }
    @Test func extremeAspectRatioIsDemotedNotDeleted() {
        let tall = candidate("/tall.jpg", .openGraph, 1600, 12000), normal = candidate("/normal.jpg", .rssMedia, 800, 600)
        #expect(ArticleImagePolicy.ranked([tall, normal]) == [normal, tall])
        #expect(!ArticleImagePolicy.permits(tall, use: .hero))
    }
    @Test func heroAndCardThresholdsAreCentralized() {
        let low = candidate("/a.jpg", .rssThumbnail, 240, 135), medium = candidate("/b.jpg", .rssMedia, 800, 600)
        #expect(ArticleImagePolicy.quality(low) == .low)
        #expect(ArticleImagePolicy.quality(medium) == .medium)
        #expect(!ArticleImagePolicy.permits(low, use: .hero) && ArticleImagePolicy.permits(low, use: .card))
        #expect(!ArticleImagePolicy.permits(medium, use: .hero))
        #expect(ArticleImagePolicy.quality(candidate("/unknown.jpg")) == .unknown)
    }
    @Test func extractedFragmentImagesNeedNoArticleWrapper() {
        #expect(ArticleImageHTML.candidates("<img src='/photo.jpg'>", baseURL: base).isEmpty)
        #expect(ArticleImageHTML.candidates("<img src='/photo.jpg'>", baseURL: base, extracted: true).count == 1)
    }
    @Test func invalidOGFallsBackToRSS() async {
        let page = ImageRequestSpy(Data("<meta property='og:image' content='/bad.jpg'><meta property='og:image:width' content='1600'>".utf8))
        let bytes = ImageRequestSpy(ArticleImageFixture.raster(600, 400), failPaths: ["/bad.jpg"])
        let resolver = ArticleImageResolver(pages: .init(directory: nil, fetch: { try await page.fetch($0) }),
            images: .init(directory: nil, fetch: { try await bytes.fetch($0) }), directory: nil)
        let result = await resolver.resolve(article())
        #expect(result.preferred?.url.path == "/rss.jpg")
        #expect(await bytes.calls.contains { $0.path == "/bad.jpg" })
    }
    @Test func allImagesInvalidReturnsTypography() async {
        let resolver = ArticleImageResolver(pages: .init(directory: nil, fetch: { _ in throw URLError(.notConnectedToInternet) }),
            images: .init(directory: nil, fetch: { _ in Data("not an image".utf8) }), directory: nil)
        #expect(await resolver.resolve(article()).preferred == nil)
    }
    @Test func cachedHTMLDoesNotFetchPageAgain() async {
        let requests = ImageRequestSpy(Data())
        let pages = ArticleImagePageStore(directory: nil, fetch: { try await requests.fetch($0) })
        await pages.ingest(ArticleImageFixture.page, url: base)
        let data = ArticleImageFixture.raster()
        let resolver = ArticleImageResolver(pages: pages, images: .init(directory: nil, fetch: { _ in data }), directory: nil)
        #expect(await resolver.resolve(article()).quality == .high)
        #expect(await requests.calls.isEmpty)
    }
    @Test func extractedArticleHTMLDoesNotFetchPageAgain() async {
        let requests = ImageRequestSpy(Data()), data = ArticleImageFixture.raster()
        var value = article(); value.contentSource = .extractedReaderContent
        value.contentHTML = "<figure><img src='/lead.jpg' width='1600' height='900'></figure>"
        let resolver = ArticleImageResolver(pages: .init(directory: nil, fetch: { try await requests.fetch($0) }),
            images: .init(directory: nil, fetch: { _ in data }), directory: nil)
        #expect(await resolver.resolve(value).preferred?.url.path == "/lead.jpg")
        #expect(await requests.calls.isEmpty)
    }
    @Test func rssSummaryHTMLDoesNotDisableLazyEnrichment() async {
        let requests = ImageRequestSpy(Data(ArticleImageFixture.page.utf8)), data = ArticleImageFixture.raster()
        var value = article(); value.contentSource = .rssDescription; value.contentHTML = "<p>Summary</p>"
        let resolver = ArticleImageResolver(pages: .init(directory: nil, fetch: { try await requests.fetch($0) }),
            images: .init(directory: nil, fetch: { _ in data }), directory: nil)
        #expect(await resolver.resolve(value).quality == .high)
        #expect(await requests.calls.count == 1)
    }
    @Test func highQualityRSSSkipsPageNetwork() async {
        let requests = ImageRequestSpy(Data()), data = ArticleImageFixture.raster()
        var value = article(); value.rssImages[0].width = 1600; value.rssImages[0].height = 900
        let resolver = ArticleImageResolver(pages: .init(directory: nil, fetch: { try await requests.fetch($0) }),
            images: .init(directory: nil, fetch: { _ in data }), directory: nil)
        #expect(await resolver.resolve(value).quality == .high)
        #expect(await requests.calls.isEmpty)
    }
    @Test func resolvedResultPersistsAcrossResolverRestart() async {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        let page = ImageRequestSpy(Data(ArticleImageFixture.page.utf8)), bytes = ImageRequestSpy(ArticleImageFixture.raster())
        let pages = ArticleImagePageStore(directory: path.appendingPathComponent("pages"), fetch: { try await page.fetch($0) })
        let images = ArticleImageCache(directory: path.appendingPathComponent("images"), fetch: { try await bytes.fetch($0) })
        let first = await ArticleImageResolver(pages: pages, images: images, directory: path).resolve(article())
        let restartedPages = ArticleImagePageStore(directory: path.appendingPathComponent("pages"), fetch: { try await page.fetch($0) })
        let again = await ArticleImageResolver(pages: restartedPages, images: images, directory: path).resolve(article())
        #expect(first.resolvedAt == again.resolvedAt && first.preferred == again.preferred)
        #expect(await page.calls.count == 1)
        #expect(await bytes.calls.count == 1)
    }
    @Test func identicalImageURLUsesMemoryThenDisk() async throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        let requests = ImageRequestSpy(ArticleImageFixture.raster())
        let cache = ArticleImageCache(directory: path, fetch: { try await requests.fetch($0) })
        let first = try await cache.data(for: base)
        #expect(try await cache.data(for: base) == first)
        let restarted = ArticleImageCache(directory: path, fetch: { try await requests.fetch($0) })
        #expect(try await restarted.data(for: base) == first)
        #expect(await requests.calls.count == 1)
    }
    @Test func concurrentPageRequestsAreCoalesced() async {
        let requests = ImageRequestSpy(Data(ArticleImageFixture.page.utf8))
        let pages = ArticleImagePageStore(directory: nil, fetch: { try await requests.fetch($0) })
        async let a = pages.page(base, allowNetwork: true)
        async let b = pages.page(base, allowNetwork: true)
        let (one, two) = await (a, b)
        #expect(one?.candidates == two?.candidates)
        #expect(await requests.calls.count == 1)
    }
    @Test func ongoingReaderExtractionIsReused() async {
        let requests = ImageRequestSpy(Data())
        let pages = ArticleImagePageStore(directory: nil, fetch: { try await requests.fetch($0) })
        await pages.beginExtraction(base)
        async let waiting = pages.page(base, allowNetwork: true)
        await pages.endExtraction(base, html: ArticleImageFixture.page)
        let snapshot = await waiting
        #expect(snapshot?.candidates.isEmpty == false)
        #expect(await requests.calls.isEmpty)
    }
    @Test func changedRSSMetadataInvalidatesResolvedChoice() async {
        let data = ArticleImageFixture.raster()
        let images = ArticleImageCache(directory: nil, fetch: { _ in data })
        let resolver = ArticleImageResolver(pages: .init(directory: nil, fetch: { _ in Data() }), images: images, directory: nil)
        var value = article(); value.rssImages[0].width = 1600; value.rssImages[0].height = 900
        let first = await resolver.resolve(value)
        value.rssImages[0].url = URL(string: "https://example.com/new.jpg")!
        let second = await resolver.resolve(value)
        #expect(first.preferred?.url != second.preferred?.url)
    }
    @Test func concurrentImageConsumersShareOneDownload() async throws {
        let requests = ImageRequestSpy(ArticleImageFixture.raster())
        let cache = ArticleImageCache(directory: nil, fetch: { try await requests.fetch($0) })
        async let hero = cache.data(for: base)
        async let card = cache.data(for: base)
        let (a, b) = try await (hero, card)
        #expect(a == b)
        #expect(await requests.calls.count == 1)
    }
    @Test func pageFailureStillKeepsThumbnailForSmallCard() async {
        let data = ArticleImageFixture.raster(240, 135)
        let resolver = ArticleImageResolver(pages: .init(directory: nil, fetch: { _ in throw URLError(.timedOut) }),
            images: .init(directory: nil, fetch: { _ in data }), directory: nil)
        let result = await resolver.resolve(article())
        #expect(result.quality == .low && result.image(for: .hero) == nil)
        #expect(result.image(for: .card)?.url.path == "/rss.jpg")
    }
    @Test func incorrectRSSDimensionsDoNotPreventEnrichment() async {
        let requests = ImageRequestSpy(Data("<meta property='og:image' content='/actual-large.jpg'>".utf8))
        let small = ArticleImageFixture.raster(240, 135), large = ArticleImageFixture.raster()
        var value = article(); value.rssImages[0].width = 1600; value.rssImages[0].height = 900
        let resolver = ArticleImageResolver(pages: .init(directory: nil, fetch: { try await requests.fetch($0) }),
            images: .init(directory: nil, fetch: { $0.path == "/rss.jpg" ? small : large }), directory: nil)
        let result = await resolver.resolve(value)
        #expect(result.preferred?.url.path == "/actual-large.jpg" && result.quality == .high)
        #expect(await requests.calls.count == 1)
    }
}
