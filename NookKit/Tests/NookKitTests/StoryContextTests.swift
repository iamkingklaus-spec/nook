import Foundation
import Testing
@testable import NookKit

enum StoryFixture {
    static func article(_ id: String = "a", host: String = "bbc.com", title: String = "Federal regulators investigate Acme safety scandal", days: Double = 0) -> Article {
        Article(id: id, feedID: host, title: title,
            summary: "Federal regulators investigate Acme safety scandal after engineers reveal dangerous battery defects.",
            bodyParagraphs: [], publishedAt: Date(timeIntervalSince1970: 1_780_000_000 + days * 86400),
            url: URL(string: "https://\(host)/\(id)")!, estimatedReadMinutes: 1, isRead: false, isStarred: false)
    }
}
@Suite("Conservative related coverage")
struct StoryContextTests {
    @Test func sameEventAcrossSources() throws {
        let a = StoryFixture.article(), b = StoryFixture.article("b", host: "npr.org")
        let cluster = try #require(StoryClustering.cluster(for: a, candidates: [a,b]))
        #expect(cluster.related(to: a).map(\.id) == ["b"])
    }
    @Test func sameCompanyDifferentEvent() {
        let b = StoryFixture.article("b", host: "npr.org", title: "Acme launches new satellite internet service")
        #expect(!StoryClustering.sameEvent(StoryFixture.article(), b))
    }
    @Test func distantDateDoesNotCluster() {
        #expect(!StoryClustering.sameEvent(StoryFixture.article(), StoryFixture.article("b", host: "npr.org", days: 30)))
    }
    @Test func currentArticleAndSamePublisherExcluded() {
        let a = StoryFixture.article(), same = StoryFixture.article("b")
        #expect(StoryClustering.cluster(for: a, candidates: [a,same]) == nil)
    }
    @Test func canonicalDuplicatesExcluded() {
        var copy = StoryFixture.article("copy"); copy.url = StoryFixture.article().url.appending(queryItems: [URLQueryItem(name: "utm_source", value: "test")])
        #expect(StoryClustering.candidates(for: StoryFixture.article(), in: [StoryFixture.article(),copy]).count == 1)
    }
    @Test func boundedCandidateWindow() {
        let articles = (0..<1000).map { StoryFixture.article("\($0)", host: "npr.org", days: Double($0)/100) }
        #expect(StoryClustering.candidates(for: StoryFixture.article(), in: articles).count <= 300)
    }
}
