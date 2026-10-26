import Foundation
import Testing
@testable import NookKit

@Suite("Saved Explain Word details") @MainActor
struct VocabularyDetailTests {
    private func explanation() throws -> LearningExplanation {
        var value = try LearningExplanationProtocol.decode(WordV2Fixture.induced, type: .word)
        value.pronunciation = "/ɪnˈdjuːs/"
        value.antonyms = [.init(word: "prevent", distinction: "强调阻止发生。")]
        return value
    }

    private func legacyData(_ entry: VocabularyEntry, removeV2: Bool = false) throws -> Data {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        object.removeValue(forKey: "explanationSnapshot")
        if removeV2 {
            for key in ["partOfSpeech", "synonyms", "wordFamily", "collocations"] { object.removeValue(forKey: key) }
        }
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func writeLegacy(_ entry: VocabularyEntry, directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let object = try JSONSerialization.jsonObject(with: legacyData(entry))
        try JSONSerialization.data(withJSONObject: ["version": 1, "entries": [object]])
            .write(to: directory.appending(path: "vocabulary.json"))
    }

    @Test func fullExplanationSnapshotSurvivesRestart() throws {
        let root = LearningFixture.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let selection = try WordV2Fixture.selection(), value = try explanation()
        let saved = try ReaderLearningStore(directory: root).save(selection: selection, explanation: value)
        let loaded = try #require(ReaderLearningStore(directory: root).entries.first)
        #expect(loaded == saved)
        #expect(loaded.savedExplanation == value)
        #expect(loaded.savedExplanation.englishDefinition != nil && loaded.savedExplanation.usage != nil)
        #expect(loaded.savedExplanation.pronunciation != nil && loaded.savedExplanation.antonyms?.count == 1)
        #expect(loaded.originalSentence == selection.sentence)
    }

    @Test func savedDetailsDoNotDependOnExplanationCache() throws {
        let root = LearningFixture.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ReaderLearningStore(directory: root)
        let selection = try WordV2Fixture.selection(), value = try explanation()
        let key = LearningCacheKey(selection: selection, type: .word, model: "old-model")
        try store.cache(value, for: key)
        try store.save(selection: selection, explanation: value)
        try FileManager.default.removeItem(at: root.appending(path: "explanations-v2.json"))
        let reopened = ReaderLearningStore(directory: root)
        #expect(reopened.cached(key, type: .word) == nil)
        #expect(reopened.entries.first?.savedExplanation == value)
    }

    @Test func oldestVocabularyDecodesWithoutInventingMissingDetails() throws {
        let saved = VocabularyEntry(selection: try WordV2Fixture.selection(), explanation: try explanation())
        let old = try JSONDecoder().decode(VocabularyEntry.self, from: legacyData(saved, removeV2: true))
        #expect(old.explanationSnapshot == nil)
        #expect(old.savedExplanation.meaning == saved.meaning && old.savedExplanation.lemma == saved.lemma)
        #expect(old.savedExplanation.englishDefinition == nil && old.savedExplanation.usage == nil)
        #expect(old.savedExplanation.example == nil && old.savedExplanation.pronunciation == nil)
        #expect(old.originalSentence == saved.originalSentence && old.articleURL == saved.articleURL)
    }

    @Test func legacyV2DetailsRemainVisible() throws {
        let saved = VocabularyEntry(selection: try WordV2Fixture.selection(), explanation: try explanation())
        let old = try JSONDecoder().decode(VocabularyEntry.self, from: legacyData(saved))
        #expect(old.explanationSnapshot == nil)
        #expect(old.savedExplanation.partOfSpeech == saved.partOfSpeech)
        #expect(old.savedExplanation.synonyms == saved.synonyms)
        #expect(old.savedExplanation.wordFamily == saved.wordFamily)
        #expect(old.savedExplanation.collocations == saved.collocations)
    }

    @Test func explicitSaveUpgradesLegacyEntryWithoutDuplicatingOrChangingDate() throws {
        let root = LearningFixture.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let selection = try WordV2Fixture.selection(), value = try explanation()
        let old = VocabularyEntry(selection: selection, explanation: value, createdAt: Date(timeIntervalSince1970: 100))
        try writeLegacy(old, directory: root)
        let store = ReaderLearningStore(directory: root)
        let upgraded = try store.save(selection: selection, explanation: value)
        #expect(store.entries.count == 1 && upgraded.id == old.id && upgraded.createdAt == old.createdAt)
        #expect(upgraded.savedExplanation == value)
        #expect(ReaderLearningStore(directory: root).entries == [upgraded])
    }

    @Test func completeSnapshotKeepsOriginalSaveTimeExplanation() throws {
        let root = LearningFixture.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ReaderLearningStore(directory: root), selection = try WordV2Fixture.selection()
        let first = try store.save(selection: selection, explanation: explanation())
        var later = try explanation(); later.usage = "不同的后续解释。"
        let second = try store.save(selection: selection, explanation: later)
        #expect(first == second && store.entries.count == 1)
        #expect(second.savedExplanation.usage != later.usage)
    }

    @Test func sameWordInDifferentContextsKeepsSeparateExplanations() throws {
        let root = LearningFixture.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ReaderLearningStore(directory: root)
        var river = try LearningFixture.explanation()
        river.meaning = "河岸"
        var finance = river; finance.meaning = "银行"; finance.usage = "这里指金融机构。"
        let a = try store.save(selection: LearningFixture.selection(), explanation: river)
        let b = try store.save(selection: LearningFixture.selection("She works at the bank."), explanation: finance)
        let loaded = ReaderLearningStore(directory: root)
        #expect(loaded.entries.count == 2 && a.id != b.id)
        #expect(loaded.entries.first(where: { $0.id == a.id })?.savedExplanation == river)
        #expect(loaded.entries.first(where: { $0.id == b.id })?.savedExplanation == finance)
    }

    @Test func phraseSnapshotPreservesExpressionKind() throws {
        let selection = try WordV2Fixture.selection("take into account", text: "We take into account the cost.")
        let value = try LearningExplanationProtocol.decode(WordV2Fixture.phrase, type: .word)
        let saved = VocabularyEntry(selection: selection, explanation: value)
        let loaded = try JSONDecoder().decode(VocabularyEntry.self, from: JSONEncoder().encode(saved))
        #expect(loaded.savedExplanation == value && loaded.savedExplanation.kind == .phrase)
    }
}
