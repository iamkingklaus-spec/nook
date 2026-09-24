import Foundation
import Testing
@testable import NookKit

@Suite("Reader content quality")
struct ReaderContentQualityTests {
    private func assess(_ html: String, summary: String = "",
                        source: ArticleContentSource = .extractedReaderContent,
                        status: ReaderQualityEvaluator.ParserStatus = .succeeded) -> ReaderQualityAssessment {
        ReaderQualityEvaluator.assess(html: html, summary: summary, source: source, parserStatus: status)
    }

    @Test func shortNewsIsNotAutomaticallySummary() {
        let result = assess("<p>The bridge reopened at noon.</p>", summary: "Transport update")
        #expect(result.quality == .fullCandidate)
        #expect(result.characterCount < 80)
    }
    @Test func shortChineseBriefIsAlsoCandidate() {
        #expect(assess("<p>当地机场已恢复正常运行。</p>").quality == .fullCandidate)
    }
    @Test func equalSummaryIsUncertainEvenWhenLong() {
        let text = String(repeating: "Officials discussed the plan during the meeting. ", count: 30)
        let result = assess("<p>\(text)</p>", summary: text)
        #expect(result.quality == .possiblySummary)
        #expect(result.summarySimilarity == 1)
    }
    @Test func similarSummaryIgnoresMarkupAndPunctuation() {
        #expect(assess("<p>The bridge <b>reopened</b> at noon!</p>",
                       summary: "The bridge reopened at noon.").quality == .possiblySummary)
    }
    @Test func expandedBodyIsNotJustItsStandfirst() {
        #expect(assess("<p>The bridge reopened.</p><p>Engineers replaced damaged cables overnight.</p><p>All bus routes are operating again.</p>",
                       summary: "The bridge reopened.").quality == .fullCandidate)
    }
    @Test func rssDescriptionIsExplicitSummaryRegardlessOfLength() {
        #expect(assess("<p>\(String(repeating: "A substantial news summary. ", count: 100))</p>",
                       source: .rssDescription).quality == .summaryOnly)
    }
    @Test func accessGateAloneIsUnavailable() {
        #expect(assess("<h1>Subscribe to continue</h1><p>Already a subscriber? Sign in.</p>").quality == .unavailable)
    }
    @Test func loginFormIsUnavailable() {
        #expect(assess("<form>Login<input type='password'></form>").quality == .unavailable)
    }
    @Test func teaserBehindPaywallIsUncertain() {
        let body = "The council has approved a plan for new housing near the station. Residents will be consulted next month about transport and schools."
        let result = assess("<p>\(body)</p><p>Subscribe to read the full story.</p>")
        #expect(result.quality == .possiblySummary)
        #expect(result.hasAccessPrompt)
        #expect(result.paragraphCount == 2)
    }
    @Test func reportingAboutLoginIsNotAPaywall() {
        #expect(assess("<p>The report explains why users must sign in to read their private messages.</p>").quality == .fullCandidate)
    }
    @Test func continueReadingIsTeaserEvidence() {
        #expect(assess("<p>Work has begun on the project.</p><p>Continue reading</p>").quality == .possiblySummary)
    }
    @Test func failedParserCannotCertifyBody() {
        #expect(assess("<p>Returned some text.</p>", status: .failed).quality == .possiblySummary)
    }
    @Test func emptyAndImageOnlyAreUnavailable() {
        #expect(assess("   ").quality == .unavailable)
        #expect(assess("<img src='https://example.com/a.jpg'>").quality == .unavailable)
    }
    @Test func titleAloneDoesNotEstablishCompleteBody() {
        #expect(assess("<h1>A developing story</h1>").quality == .possiblySummary)
    }
    @Test func semanticStructuresContributeWithoutMutation() {
        let html = "<blockquote><p>A witness statement.</p></blockquote><ul><li>First finding.</li><li>Second finding.</li></ul><pre>let x = 1</pre><table><tr><td>Value</td></tr></table>"
        let result = assess(html)
        #expect(result.quality == .fullCandidate)
        #expect(result.semanticBlockCount >= 4)
        #expect(result.paragraphCount >= 4)
    }
    @Test func noticesDoNotClaimSummaryIsFull() {
        #expect(ReaderContentQuality.summaryOnly.notice == "当前仅获取到 RSS 摘要，未能提取完整正文。")
        #expect(ReaderContentQuality.possiblySummary.notice == "当前内容可能仅为摘要。")
        #expect(ReaderContentQuality.fullCandidate.notice == nil)
    }
}

@Suite("Reader quality selection") @MainActor
struct ReaderContentSelectionTests {
    private func article() -> Article {
        var article = Fixture.article("quality", feedID: "feed")
        article.summary = "RSS standfirst."
        return article
    }
    private let body = "<p>The bridge reopened at noon after repairs.</p><p>Bus routes resumed an hour later.</p>"

    @Test func rssFullComesBeforeNetwork() async {
        var article = article()
        article.sourceContents = [.init(source: .rssFullContent, content: body, format: .html)]
        var calls = 0
        let result = await ReaderContentResolver.resolve(article: article, preferred: .legibility) { _ in
            calls += 1; return .failed
        }
        #expect(calls == 0)
        #expect(result.candidate?.source == .rssFullContent)
        #expect(result.candidate?.assessment.quality == .fullCandidate)
    }
    @Test func declaredPartialRSSStillNeedsExtraction() async {
        var article = article()
        article.sourceContents = [.init(source: .rssFullContent, content: body, format: .html, quality: .partial)]
        let result = await ReaderContentResolver.resolve(article: article, preferred: .legibility) { _ in .failed }
        #expect(result.attempts.count == 2)
        #expect(result.candidate?.assessment.quality == .possiblySummary)
    }
    @Test func refreshedBodyChangesDocumentHashWithoutTranslationRequest() async {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let counter = QualityTranslationCounter()
        let controller = BlockReaderTranslationController(cache: BlockTranslationCache(directory: root),
            transport: BlockTranslationTransport { _, _ in await counter.request() })
        let article = article()
        let before = BlockReaderInput(articleID: article.id, url: article.url, html: body,
                                      paragraphs: [], source: .extractedReaderContent)
        let after = BlockReaderInput(articleID: article.id, url: article.url, html: "<p>Updated facts.</p>",
                                     paragraphs: [], source: .extractedReaderContent)
        await controller.load(before)
        controller.mode = .bilingual
        await controller.load(after)
        #expect(BlockReaderDocument(input: before).document.documentHash != BlockReaderDocument(input: after).document.documentHash)
        #expect(await counter.calls == 0)
        #expect(controller.translatedCount == 0)
    }
    @Test func firstFailureUsesAlternateParser() async {
        let result = await ReaderContentResolver.resolve(article: article(), preferred: .legibility) { engine in
            engine == .legibility ? .failed : .success(.init(html: body, engine: engine))
        }
        #expect(result.attempts == [.legibility, .readability])
        #expect(result.candidate?.engine == .readability)
        #expect(result.candidate?.assessment.quality == .fullCandidate)
    }
    @Test func lowQualityFirstParserUsesBetterAlternate() async {
        let result = await ReaderContentResolver.resolve(article: article(), preferred: .readability) { engine in
            .success(.init(html: engine == .readability ? "<p>RSS standfirst.</p>" : body, engine: engine))
        }
        #expect(result.attempts == [.readability, .legibility])
        #expect(result.candidate?.html == body)
    }
    @Test func bothFailuresFallBackToExplicitSummary() async {
        let result = await ReaderContentResolver.resolve(article: article(), preferred: .legibility) { _ in .failed }
        #expect(result.attempts.count == 2)
        #expect(result.candidate?.assessment.quality == .summaryOnly)
        #expect(result.candidate?.source == .rssDescription)
    }
    @Test func timeoutAlsoTriesAlternate() async {
        let result = await ReaderContentResolver.resolve(article: article(), preferred: .legibility) { engine in
            engine == .legibility ? .timedOut : .success(.init(html: body, engine: engine))
        }
        #expect(result.candidate?.assessment.quality == .fullCandidate)
    }
    @Test func failedRefreshPreservesCachedFullBody() async {
        let cached = ReaderContentCandidate(html: body, source: .extractedReaderContent,
                                            summary: "", isCached: true)
        let result = await ReaderContentResolver.resolve(article: article(), cached: cached,
            preferred: .legibility, forceParser: true) { _ in .failed }
        #expect(result.attempts.count == 2)
        #expect(result.candidate?.html == body)
        #expect(result.candidate?.isCached == true)
    }
    @Test func successfulButSummaryRefreshCannotDowngradeFull() async {
        let cached = ReaderContentCandidate(html: body, source: .extractedReaderContent,
                                            summary: "", isCached: true)
        let result = await ReaderContentResolver.resolve(article: article(), cached: cached,
            preferred: .legibility, forceParser: true) { engine in
                .success(.init(html: "<p>RSS standfirst.</p>", engine: engine))
            }
        #expect(result.candidate?.html == body)
    }
    @Test func cachedFullReopensWithoutExtraction() async {
        let cached = ReaderContentCandidate(html: body, source: .extractedReaderContent,
                                            summary: "", isCached: true)
        var calls = 0
        let result = await ReaderContentResolver.resolve(article: article(), cached: cached, preferred: .readability) { _ in
            calls += 1; return .failed
        }
        #expect(calls == 0)
        #expect(result.candidate?.html == body)
    }
    @Test func internalFallbackDoesNotRepeatReadability() async {
        var calls = 0
        let result = await ReaderContentResolver.resolve(article: article(), preferred: .legibility) { _ in
            calls += 1
            return .success(.init(html: "<p>RSS standfirst.</p>", engine: .readability, fellBack: true))
        }
        #expect(calls == 1)
        #expect(result.attempts == [.legibility, .readability])
    }
    @Test func noBodyAndNoSummaryIsUnavailable() async {
        var article = article(); article.summary = ""
        let result = await ReaderContentResolver.resolve(article: article, preferred: .legibility) { _ in .failed }
        #expect(result.candidate == nil)
    }
    @Test func goneOriginalKeepsCachedFull() async {
        let cached = ReaderContentCandidate(html: body, source: .extractedReaderContent,
                                            summary: "", isCached: true)
        let result = await ReaderContentResolver.resolve(article: article(), cached: cached,
            preferred: .legibility, forceParser: true) { _ in .gone }
        #expect(result.originalGone)
        #expect(result.candidate?.html == body)
        #expect(result.attempts.count == 1)
    }
    @Test func comparingCandidatesRetainsStructure() async {
        let html = body + "<blockquote><p>A quote.</p></blockquote><ul><li>Item</li></ul><pre>code</pre><img src='https://example.com/x.jpg'><table><tr><td>1</td></tr></table>"
        let result = await ReaderContentResolver.resolve(article: article(), preferred: .legibility) { engine in
            .success(.init(html: html, engine: engine))
        }
        #expect(result.candidate?.html == html)
    }
}

private actor QualityTranslationCounter {
    var calls = 0
    func request() -> String { calls += 1; return "{}" }
}

@Suite("Reader quality persistence")
struct ReaderQualityPersistenceTests {
    private let full = ReaderContentValue(status: .success, html: "<p>A complete news brief.</p>",
        quality: .fullCandidate, qualityVersion: 1, source: .extractedReaderContent)

    @Test func oldRecordsStillDecode() throws {
        let value = try JSONDecoder().decode(ReaderContentValue.self, from: Data(#"{"s":"success","h":"<p>Legacy body.</p>"}"#.utf8))
        #expect(value.quality == nil)
        #expect(value.source == nil)
        #expect(value.protectsBody)
    }
    @Test func metadataAndHashRoundTrip() throws {
        let restored = try JSONDecoder().decode(ReaderContentValue.self, from: JSONEncoder().encode(full))
        #expect(restored == full)
        #expect(restored.contentHash == full.contentHash)
    }
    @Test func onlyContentChangesContentHash() {
        var next = full
        next.quality = .possiblySummary; next.qualityVersion = 2
        #expect(next.contentHash == full.contentHash)
        next.html = "<p>Updated facts.</p>"
        #expect(next.contentHash != full.contentHash)
    }
    @Test func summaryDoesNotProtectAsFullBody() {
        let summary = ReaderContentValue(status: .success, html: "<p>RSS.</p>", quality: .summaryOnly)
        #expect(!summary.protectsBody)
    }
    @Test func failedAndSummaryWritesPreserveFullAcrossReload() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = ReaderStorage(directoryURL: root)
        let store = ReaderContentStore(storage: storage, deviceID: "a")
        await store.record(full, for: "article")
        await store.record(.init(status: .failed, html: nil), for: "article")
        await store.record(.init(status: .success, html: "RSS", quality: .summaryOnly), for: "article")
        let reopened = ReaderContentStore(storage: storage, deviceID: "a")
        await reopened.reload()
        #expect(await reopened.value(for: "article") == full)
    }
    @Test func newerPeerSummaryCannotDiscardFullAndPeersConverge() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = ReaderStorage(directoryURL: root)
        let a = ReaderContentStore(storage: storage, deviceID: "a")
        let b = ReaderContentStore(storage: storage, deviceID: "b")
        await a.record(full, for: "article")
        // b has not observed a yet, representing a disconnected device.
        await b.record(.init(status: .success, html: "RSS", quality: .summaryOnly), for: "article")
        await a.reload(); await b.reload()
        #expect(await a.value(for: "article") == full)
        #expect(await b.value(for: "article") == full)
    }
    @Test func successfulFullRefreshUpdatesDurableContent() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = ReaderStorage(directoryURL: root)
        let store = ReaderContentStore(storage: storage, deviceID: "a")
        await store.record(full, for: "article")
        var updated = full; updated.html = "<p>Revised full body.</p>"
        await store.record(updated, for: "article")
        await store.reload()
        #expect(await store.value(for: "article") == updated)
    }
}
