import Foundation
import Observation

/// Device-local learning data. No library, shard, category or translation cache
/// dependencies. Vocabulary writes are atomic and errors remain visible.
@MainActor @Observable
public final class ReaderLearningStore {
    public static let shared = ReaderLearningStore()
    public private(set) var entries: [VocabularyEntry] = []
    public private(set) var loadError: String?
    private let directory: URL
    private var cache: [String: CachedExplanation] = [:]
    private struct VocabularyFile: Codable { var version = 1; var entries: [VocabularyEntry] }
    private struct CachedExplanation: Codable {
        let key: LearningCacheKey
        let value: LearningExplanation
        let createdAt: Date
    }

    public convenience init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.init(directory: root.appending(path: "Nook/Learning", directoryHint: .isDirectory))
    }

    init(directory: URL) {
        self.directory = directory
        let vocabularyURL = directory.appending(path: "vocabulary.json")
        if FileManager.default.fileExists(atPath: vocabularyURL.path) {
            do {
                let file = try JSONDecoder().decode(VocabularyFile.self, from: Data(contentsOf: vocabularyURL))
                guard file.version == 1 else { throw LearningError.unsupportedVersion }
                entries = file.entries
            } catch { loadError = "生词本读取失败，已保留原文件；请恢复文件后重新打开 App。" }
        }
        if let data = try? Data(contentsOf: directory.appending(path: "explanations-v1.json")),
           let saved = try? JSONDecoder().decode([String: CachedExplanation].self, from: data) {
            cache = saved
        }
    }

    func cached(_ key: LearningCacheKey, type: LearningExplanationType) -> LearningExplanation? {
        guard let item = cache[key.digest], item.key == key,
              (try? item.value.validate(for: type)) != nil else { return nil }
        return item.value
    }

    func cache(_ value: LearningExplanation, for key: LearningCacheKey) throws {
        try value.validate(for: value.type)
        var next = cache
        next[key.digest] = CachedExplanation(key: key, value: value, createdAt: .now)
        if next.count > 250 {
            let oldest = next.sorted { $0.value.createdAt < $1.value.createdAt }.prefix(next.count - 250)
            for item in oldest { next[item.key] = nil }
        }
        try write(next, to: "explanations-v1.json")
        cache = next
    }

    @discardableResult
    func save(selection: LearningSelection, explanation: LearningExplanation) throws -> VocabularyEntry {
        guard selection.isWord else { throw LearningError.malformed }
        try explanation.validate(for: .word)
        let entry = VocabularyEntry(selection: selection, explanation: explanation)
        if let existing = entries.first(where: { $0.id == entry.id }) { return existing }
        let next = [entry] + entries
        try persistVocabulary(next)
        entries = next
        return entry
    }

    public func delete(_ id: String) throws {
        let next = entries.filter { $0.id != id }
        try persistVocabulary(next)
        entries = next
    }

    public func search(_ query: String) -> [VocabularyEntry] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? entries : entries.filter {
            [$0.word, $0.lemma, $0.meaning, $0.originalSentence, $0.articleTitle, $0.publisher]
                .contains { $0.localizedStandardContains(query) }
        }
    }

    private func persistVocabulary(_ next: [VocabularyEntry]) throws {
        guard loadError == nil else { throw LearningError.storage }
        try write(VocabularyFile(entries: next), to: "vocabulary.json")
    }

    private func write<T: Encodable>(_ value: T, to name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(value)
        try data.write(to: directory.appending(path: name), options: .atomic)
    }
}
