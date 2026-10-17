import Foundation
import Testing
@testable import NookKit

@Suite("Device-local reading state") @MainActor
struct ReadingStateTests {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    var article: Article { Fixture.article("a", feedID: "f") }
    let anchors = ["a", "b", "c", "d", "e"].map { ReaderReadingAnchor(blockID: $0) }

    private func populated(file: URL? = nil) -> ReadingStateStore {
        let store = ReadingStateStore(file: file)
        store.opened(article, at: now)
        store.update(article, progress: 0.42, anchor: anchors[1], mode: .bilingual, at: now)
        return store
    }

    @Test func positionAndModeSurviveRestart() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("position-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = populated(file: file); store.flush()
        let restored = ReadingStateStore(file: file)
        #expect(restored.state(for: article)?.readingProgress == 0.42)
        #expect(restored.state(for: article)?.lastVisibleBlockID == "b")
        #expect(restored.state(for: article)?.mode == .bilingual)
        #expect(ReaderResumePosition.anchor(for: restored.state(for: article), in: anchors) == anchors[1])
    }
    @Test func existingBlockWinsOverApproximateProgress() {
        let store = populated()
        store.update(article, progress: 0.9, anchor: anchors[1], mode: .english, at: now)
        #expect(ReaderResumePosition.anchor(for: store.state(for: article), in: anchors) == anchors[1])
    }
    @Test func missingBlockFallsBackToProgress() {
        let store = populated()
        store.update(article, progress: 0.75, anchor: .init(blockID: "removed"), mode: .english, at: now)
        #expect(ReaderResumePosition.anchor(for: store.state(for: article), in: anchors) == anchors[3])
    }
    @Test func fragmentFallbackRetainsSourceBlockIdentity() {
        let store = populated()
        store.update(article, progress: 0.7, anchor: .init(blockID: "b", presentationID: "b/old"), mode: .english, at: now)
        let fragments = [ReaderReadingAnchor(blockID: "b", presentationID: "b/new")]
        #expect(ReaderResumePosition.anchor(for: store.state(for: article), in: fragments) == fragments[0])
    }
    @Test func lessThanFivePercentStartsAtTop() {
        let store = populated()
        store.update(article, progress: 0.04, anchor: anchors[0], mode: .english, at: now)
        #expect(ReaderResumePosition.anchor(for: store.state(for: article), in: anchors) == nil)
    }
    @Test func emptyDocumentHasNoResumeTarget() {
        #expect(ReaderResumePosition.anchor(for: populated().state(for: article), in: []) == nil)
    }
    @Test func repeatedScrollEventsAreThrottledAndDisappearFlushes() {
        let store = populated()
        for sample in 0..<100 {
            store.update(article, progress: Double(sample) / 100, anchor: anchors[sample % 5],
                mode: .bilingual, at: now.addingTimeInterval(Double(sample) / 100))
        }
        #expect(store.writeCount == 1)
        store.flush(at: now.addingTimeInterval(1))
        #expect(store.writeCount == 2)
        store.flush(); #expect(store.writeCount == 2)
    }
    @Test func continuingScrollPersistsAtIntervalWithoutWaitingForIdle() {
        let store = populated()
        store.update(article, progress: 0.6, anchor: anchors[3], mode: .bilingual,
            at: now.addingTimeInterval(ReadingStatePolicy.writeInterval))
        #expect(store.writeCount == 2)
    }
    @Test func repeatedOpenKeepsPositionAndUsesCanonicalIdentity() {
        let store = populated()
        var alias = article; alias.id = "another-feed-id"; alias.url = URL(string: article.url.absoluteString + "#part")!
        store.opened(alias, at: now.addingTimeInterval(100))
        #expect(store.entries.count == 1)
        #expect(store.state(for: alias)?.readingProgress == 0.42)
        #expect(store.state(for: alias)?.lastOpenedAt == now.addingTimeInterval(100))
    }
    @Test func modesAndManualReadUnreadRemainIndependentOfProgress() {
        let store = populated()
        store.setMode(.chinese, for: article); #expect(store.state(for: article)?.mode == .chinese)
        store.setRead(true, for: article); #expect(store.state(for: article)?.isRead == true)
        store.setRead(false, for: article); #expect(store.state(for: article)?.isRead == false)
        #expect(store.state(for: article)?.readingProgress == 0.42)
    }
    @Test func invalidGeometryDoesNotDestroyPosition() {
        let store = populated()
        store.update(article, progress: .nan, anchor: nil, mode: .english)
        #expect(store.state(for: article)?.readingProgress == 0.42)
        store.update(article, progress: 2, anchor: anchors[4], mode: .english)
        #expect(store.state(for: article)?.readingProgress == 1)
    }
    @Test func unreadableFileIsPreserved() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("position-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let bytes = Data("broken".utf8); try bytes.write(to: file)
        let store = populated(file: file); store.flush()
        #expect(try Data(contentsOf: file) == bytes)
        #expect(store.errorMessage != nil)
    }
    @Test func localResetDiscardsPendingPositionWrite() {
        let store = populated()
        let before = store.writeCount
        store.didResetLocalData(); store.flush()
        #expect(store.entries.isEmpty)
        #expect(store.writeCount == before)
    }

}
