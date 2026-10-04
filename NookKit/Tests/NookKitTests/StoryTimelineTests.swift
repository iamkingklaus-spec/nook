import Foundation
import Testing
@testable import NookKit

@Suite("Evidence-bound timeline")
struct StoryTimelineTests {
    func cluster() -> EventCluster { EventCluster(members: [StoryFixture.article(), StoryFixture.article("b", host: "npr.org", days: 1)]) }
    func response(_ nodes: [StoryTimelineNode]) throws -> String { String(decoding: try JSONEncoder().encode(TimelineResponse(nodes: nodes)), as: UTF8.self) }
    func node(_ article: Article, date: String? = nil) -> StoryTimelineNode {
        StoryTimelineNode(date: date ?? TimelineProtocol.day(article.publishedAt), title: "调查报道", shortSummary: "监管机构调查安全问题。",
                          evidence: [TimelineEvidence(articleID: article.id, blockID: nil, quote: article.title)])
    }
    @Test func validatesAndSortsDates() throws {
        let c = cluster()
        let nodes = try TimelineProtocol.decode(response(c.members.reversed().map { node($0) }), sources: TimelineProtocol.sources(c))
        #expect(nodes.map(\.date) == nodes.map(\.date).sorted())
    }
    @Test func unsupportedDateRejected() throws {
        #expect(throws: StoryContextError.self) { try TimelineProtocol.decode(response([node(cluster().members[0], date: "1999-01-01")]), sources: TimelineProtocol.sources(cluster())) }
    }
    @Test func malformedJSONRejected() {
        #expect(throws: StoryContextError.self) { try TimelineProtocol.decode("```json {} ```", sources: []) }
    }
    @Test func duplicateEventsMerged() throws {
        let n = node(cluster().members[0])
        #expect(try TimelineProtocol.decode(response([n,n]), sources: TimelineProtocol.sources(cluster())).count == 1)
    }
    @Test func unknownSourceAndInventedQuoteRejected() throws {
        var n = node(cluster().members[0]); n.evidence = [TimelineEvidence(articleID: "unknown", blockID: nil, quote: "Made up quotation")]
        #expect(throws: StoryContextError.self) { try TimelineProtocol.decode(response([n]), sources: TimelineProtocol.sources(cluster())) }
        n.evidence = [TimelineEvidence(articleID: "a", blockID: nil, quote: "Made up quotation")]
        #expect(throws: StoryContextError.self) { try TimelineProtocol.decode(response([n]), sources: TimelineProtocol.sources(cluster())) }
    }
    @Test func changedContentAndModelInvalidateCache() {
        var article = cluster().members[0]; article.summary += " Updated evidence."
        #expect(TimelineProtocol.key(cluster(), model: .flashLite) != TimelineProtocol.key(EventCluster(members: [article, cluster().members[1]]), model: .flashLite))
        #expect(TimelineProtocol.key(cluster(), model: .flashLite) != TimelineProtocol.key(cluster(), model: .flash))
    }
    @Test func syntheticDatesExcludedAndInputBounded() {
        var a = StoryFixture.article(); a.hasExplicitPublishDate = false
        #expect(TimelineProtocol.sources(EventCluster(members: [a])).isEmpty)
        a.hasExplicitPublishDate = true; a.summary = String(repeating: "x", count: 100000)
        #expect(TimelineProtocol.sources(EventCluster(members: [a]))[0].summary.count == 1000)
    }
    @Test @MainActor func diskCacheAvoidsSecondRequest() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let c = cluster(), answer = try response([node(cluster().members[0])])
        let first = StoryTimelineController(cache: StoryContextCache(directory: directory), transport: ContextTransport { _,_,_,_ in answer })
        await first.load(c)
        #expect(first.nodes?.count == 1)
        let second = StoryTimelineController(cache: StoryContextCache(directory: directory), transport: ContextTransport { _,_,_,_ in Issue.record("Cache miss"); return "" })
        await second.load(c)
        #expect(second.cacheHit && second.nodes?.count == 1)
    }
}
