import Foundation

/// Immutable local-cleaned baseline, independent of AI masks and translations.
/// Native render topology is still rebuilt from source HTML; only an exactly
/// matching document may supply persisted block identities. Never trust a stale
/// baseline after normalization/schema/input changes.
actor ReaderLocalDocumentCache {
    static let shared = ReaderLocalDocumentCache()
    private let directory: URL?
    init(directory: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first?.appendingPathComponent("Nook/ReaderDocuments/v1", isDirectory: true)) { self.directory = directory }

    func prepare(_ input: BlockReaderInput) -> BlockReaderDocument {
        let current = BlockReaderDocument(input: input)
        guard let directory else { return current }
        let identity = ArticleDocument.digest([input.articleID, input.url.absoluteString, "local-cleanup-v1",
            String(current.document.schemaVersion), input.source.rawValue, input.html ?? ""] + input.paragraphs)
        let file = directory.appendingPathComponent(identity + ".json")
        if let data = try? Data(contentsOf: file), let cached = try? JSONDecoder().decode(ArticleDocument.self, from: data),
           cached == current.document { return current.withBaseline(cached) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(current.document).write(to: file, options: .atomic)
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            let sorted = files.filter { $0.pathExtension == "json" }.sorted {
                ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                    > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            }
            for expired in sorted.dropFirst(200) { try? FileManager.default.removeItem(at: expired) }
        } catch { /* Cache failure never prevents reading or translation. */ }
        return current
    }
}
