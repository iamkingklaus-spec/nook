import Foundation
import Testing
@testable import NookKit

@Suite("News metadata persistence")
struct ArticleNewsPersistenceTests {
    private func makeRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "nook-news-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("SQLite reopen and a fresh peer restore all fields through content/body shards")
    func replicaRoundTrip() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = ReaderStorage(directoryURL: root.appending(path: "sync"))
        let db = root.appending(path: "db")
        let article = NewsFixture.article()
        let library = Fixture.library(feeds: [Fixture.feed(article.feedID)], articles: [article])
        let replica = try ReplicaStore(syncDirectory: storage.directoryURL, deviceID: "writer", databaseDirectory: db)
        _ = try replica.recordLocal(library, retainBodies: [article.id])
        let reopened = try ReplicaStore(syncDirectory: storage.directoryURL, deviceID: "writer", databaseDirectory: db)
        #expect(try reopened.reconcile(storage: storage).library.articles.first == article)
        try reopened.publishIfNeeded(to: storage)
        let content = try #require(storage.loadOwnContentShard(deviceID: "writer"))
        #expect(content.articles[article.id]?.value == ArticleContent(article))
        #expect(storage.loadBodyShards().first?.bodies[article.id] == article.body)
        let peer = try ReplicaStore(syncDirectory: storage.directoryURL, deviceID: "peer", databaseDirectory: root.appending(path: "peer-db"))
        #expect(try peer.reconcile(storage: storage).library.articles.first == article)
        // Materializing read/category state must not alter content metadata.
        var state = DeviceStateDocument(deviceID: "peer")
        state.setCategory("mine", ArticleCategory(id: "mine", name: "Mine"), hlc: Fixture.hlc(2))
        state.setArticleCategories(article.id, ["mine"], hlc: Fixture.hlc(3))
        state.setArticleRead(article.id, true, hlc: Fixture.hlc(4))
        try storage.saveShard(state)
        let snapshot = try peer.reconcile(storage: storage)
        let materialized = DeviceStateDocument.materialize(base: snapshot.library, shards: try storage.loadShards())
        let result = try #require(materialized.articles.first)
        #expect(result.categories == ["mine"])
        #expect(result.isRead)
        #expect(ArticleContent(result) == ArticleContent(article))
        #expect(result.body == article.body)
    }

    @Test("Legacy baseline save and sidecar reload preserve new metadata without heavy inline bodies")
    func legacyStorageRoundTrip() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = ReaderStorage(directoryURL: root)
        let article = NewsFixture.article()
        try storage.save(Fixture.library(feeds: [Fixture.feed(article.feedID)], articles: [article]))
        try storage.saveContent([article.id: article.body], retain: [article.id])
        var loaded = try #require(try storage.load()?.articles.first)
        #expect(loaded.sourceContents.isEmpty)
        #expect(loaded.document == nil)
        loaded.applyBody(try #require(storage.loadContent()[article.id]))
        #expect(loaded == article)
    }

    @Test("Old content shards can be imported into SQLite and subsequently enriched")
    func legacyShardMigration() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = ReaderStorage(directoryURL: root.appending(path: "sync"))
        let old = try JSONDecoder().decode(ArticleContent.self, from: NewsFixture.legacyContent)
        var shard = ContentShardDocument(deviceID: "old-device")
        shard.articles[old.id] = LWWRegister(value: old, hlc: Fixture.hlc(1))
        try storage.saveContentShard(shard)
        let replica = try ReplicaStore(syncDirectory: storage.directoryURL, deviceID: "new-device", databaseDirectory: root.appending(path: "db"))
        let original = try #require(try replica.reconcile(storage: storage).library.articles.first)
        #expect(original.title == "Old")
        #expect(original.rssTags.isEmpty)
        var enriched = NewsFixture.article()
        enriched.id = old.id
        _ = try replica.recordLocal(Fixture.library(feeds: [], articles: [enriched]), retainBodies: [enriched.id])
        #expect(try replica.reconcile(storage: storage).library.articles.first == enriched)
    }

    @Test("LWW merge preserves whole news metadata and converges in both orders")
    func mergeConvergence() throws {
        let article = NewsFixture.article()
        var older = article
        older.newsCategory = .science
        older.heroImageURL = URL(string: "https://example.com/old.jpg")
        var a = ContentShardDocument(deviceID: "a")
        var b = ContentShardDocument(deviceID: "b")
        a.articles[article.id] = LWWRegister(value: ArticleContent(older), hlc: Fixture.hlc(1, node: "a"))
        b.articles[article.id] = LWWRegister(value: ArticleContent(article), hlc: Fixture.hlc(2, node: "b"))
        let ab = a.merged(with: b, as: "merged")
        let ba = b.merged(with: a, as: "merged")
        #expect(ab.articles == ba.articles)
        #expect(ab.merged(with: a, as: "merged").articles == ab.articles)
        #expect(ab.materialize(bodies: [article.id: article.body]).articles.first == article)
    }

    @Test("Body eviction retains news metadata and cannot fabricate a document")
    func retentionBoundary() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = ReaderStorage(directoryURL: root.appending(path: "sync"))
        let replica = try ReplicaStore(syncDirectory: storage.directoryURL, deviceID: "writer", databaseDirectory: root.appending(path: "db"))
        let article = NewsFixture.article()
        let library = Fixture.library(feeds: [], articles: [article])
        _ = try replica.recordLocal(library, retainBodies: [article.id])
        let evicted = try #require(try replica.recordLocal(library, retainBodies: []).library.articles.first)
        #expect(ArticleContent(evicted) == ArticleContent(article))
        #expect(evicted.document == nil)
        #expect(evicted.sourceContents.isEmpty)
    }

    @Test("RSS refresh through ReaderStore preserves enrichment while updating feed evidence")
    @MainActor
    func storeRefresh() throws {
        let store = ReaderStore._makeForTesting()
        let old = NewsFixture.article()
        let feed = Fixture.feed(old.feedID)
        store._mergeForTesting(ParsedFeed(feed: feed, articles: [old]))
        var fresh = old
        fresh.newsCategory = nil
        fresh.newsCategoryProvenance = nil
        fresh.document = nil
        fresh.rssTags = ["Updated tag"]
        fresh.heroImageURL = URL(string: "https://example.com/fresh.jpg")
        fresh.heroImageProvenance = .enclosure
        store._mergeForTesting(ParsedFeed(feed: feed, articles: [fresh]))
        let result = try #require(store.articles.first(where: { $0.id == old.id }))
        #expect(result.newsCategory == .technology)
        #expect(result.newsCategoryProvenance == old.newsCategoryProvenance)
        #expect(result.document == old.document)
        #expect(result.rssTags == ["Updated tag"])
        #expect(result.heroImageURL == fresh.heroImageURL)
    }
}
