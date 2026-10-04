import Foundation
import Testing
@testable import NookKit

/// Offline response fixtures exercise the client contract, not live model accuracy.
enum WordV2Fixture {
    static let induced = #"{"type":"word","expression":"induce","lemma":"induce","kind":"word","partOfSpeech":"verb","meaning":"在这里指引发变化。","englishDefinition":"to cause something to happen","usage":"induced 是过去式，后接 changes。","synonyms":[{"word":"cause","distinction":"最通用的导致。"},{"word":"trigger","distinction":"侧重触发反应，不总能替换 induce。"}],"wordFamily":[{"word":"inducement","partOfSpeech":"noun","meaning":"诱因；动机"},{"word":"inducible","partOfSpeech":"adjective","meaning":"可诱导的"}],"collocations":["induce changes","induce sleep"],"example":"The medicine can induce sleep."}"#
    static let create = #"{"type":"word","expression":"create","lemma":"create","kind":"word","partOfSpeech":"verb","meaning":"这里指创造就业机会。","englishDefinition":"to make something new exist","usage":"create 后接 jobs。","synonyms":[{"word":"generate","distinction":"强调产生结果或收益。"},{"word":"establish","distinction":"通常指建立组织或制度，不直接替换 create jobs。"}],"wordFamily":[{"word":"creation","partOfSpeech":"noun","meaning":"创造；作品"},{"word":"creative","partOfSpeech":"adjective","meaning":"有创造力的"},{"word":"creativity","partOfSpeech":"noun","meaning":"创造力"},{"word":"creator","partOfSpeech":"noun","meaning":"创作者"}],"collocations":["create jobs","create opportunities"]}"#
    static let dense = #"{"type":"word","lemma":"dense","kind":"word","partOfSpeech":"adjective","meaning":"这里指雾浓密。","englishDefinition":"thick and difficult to see through","usage":"dense 修饰 fog。","synonyms":[{"word":"thick","distinction":"描述浓雾时很自然。"}],"antonyms":[{"word":"thin","distinction":"用于雾时表示稀薄。"}],"wordFamily":[{"word":"densely","partOfSpeech":"adverb","meaning":"密集地"},{"word":"density","partOfSpeech":"noun","meaning":"密度"}],"collocations":["dense fog","dense forest"]}"#
    static let outcome = #"{"type":"word","lemma":"outcome","kind":"word","partOfSpeech":"noun","meaning":"这里指试验的最终结果。","englishDefinition":"the final result of a process","usage":"outcome of the trial 表示试验结果。","synonyms":[{"word":"result","distinction":"比 outcome 更通用。"},{"word":"consequence","distinction":"强调某行为带来的后果，常有负面意味。"}],"collocations":["a positive outcome","the outcome of a trial"]}"#
    static let phrase = #"{"type":"word","expression":"take into account","lemma":"take into account","kind":"phrase","meaning":"这里指把成本因素考虑进去。","englishDefinition":"to consider something when making a decision","usage":"take the cost into account，宾语可位于 take 与 into account 之间。","synonyms":[{"word":"consider","distinction":"更简洁通用。"},{"word":"factor in","distinction":"强调把因素纳入计算或判断。"}],"collocations":["take costs into account","take circumstances into account"]}"#
    static let old = #"{"type":"word","lemma":"bank","meaning":"河岸","englishDefinition":"land beside a river","usage":"指河边。"}"#
    static func selection(_ selected: String = "induced", text: String = "The treatment induced changes.") throws -> LearningSelection {
        let document = ArticleDocument(source: .rssFullContent, blocks: [.init(kind: .paragraph, sourceContent: text)])
        let context = LearningArticleContext(articleID: "v2", articleURL: URL(string: "https://example.com/v2")!, title: "Research", publisher: "News")
        return try #require(LearningSelection.resolve(article: context, document: document, blockID: document.blocks[0].id,
            renderedSource: text, range: (text as NSString).range(of: selected)))
    }
}

@Suite("Explain Word 2.0")
struct LearningWordV2Tests {
    @Test func inducedUsesLemmaAndContextualMeaning() throws {
        let value = try LearningExplanationProtocol.decode(WordV2Fixture.induced, type: .word)
        #expect(value.lemma == "induce" && value.meaning.contains("变化"))
        #expect(value.synonyms?.count == 2 && value.synonyms?.allSatisfy { !$0.distinction.isEmpty } == true)
        #expect(value.collocations == ["induce changes", "induce sleep"])
    }
    @Test func createParsesCommonModernWordFamily() throws {
        let value = try LearningExplanationProtocol.decode(WordV2Fixture.create, type: .word)
        #expect(value.wordFamily?.map(\.word) == ["creation", "creative", "creativity", "creator"])
        #expect(value.wordFamily?.allSatisfy { !$0.partOfSpeech.isEmpty && !$0.meaning.isEmpty } == true)
    }
    @Test func denseSupportsNaturalAntonym() throws {
        let value = try LearningExplanationProtocol.decode(WordV2Fixture.dense, type: .word)
        #expect(value.partOfSpeech == "adjective" && value.antonyms?.first?.word == "thin")
    }
    @Test func outcomeOmitsUnhelpfulFamilyAndPronunciation() throws {
        let value = try LearningExplanationProtocol.decode(WordV2Fixture.outcome, type: .word)
        #expect(value.wordFamily == nil && value.pronunciation == nil && value.antonyms == nil)
    }
    @Test func phraseDoesNotRequireWordFamily() throws {
        let selection = try WordV2Fixture.selection("take into account", text: "We take into account the cost.")
        #expect(!selection.isWord && selection.isLexicalExpression)
        let value = try LearningExplanationProtocol.decode(WordV2Fixture.phrase, type: .word)
        #expect(value.kind == .phrase && value.lemma == "take into account" && value.wordFamily == nil)
    }
    @Test func phraseWithForcedFamilyRejected() throws {
        var value = try LearningExplanationProtocol.decode(WordV2Fixture.phrase, type: .word)
        value.wordFamily = [.init(word: "accounting", partOfSpeech: "noun", meaning: "会计")]
        #expect(throws: LearningError.self) { try value.validate(for: .word) }
    }
    @Test func oldResponseStillDecodes() throws {
        let value = try LearningExplanationProtocol.decode(WordV2Fixture.old, type: .word)
        #expect(value.lemma == "bank" && value.kind == nil && value.synonyms == nil)
    }
    @Test func optionalNullsAreAllowed() throws {
        let response = WordV2Fixture.old.replacingOccurrences(of: "\"type\":\"word\"", with: "\"type\":\"word\",\"pronunciation\":null,\"wordFamily\":null")
        #expect(try LearningExplanationProtocol.decode(response, type: .word).pronunciation == nil)
    }
    @Test func alternativesNeedDistinctionsAndAreBounded() throws {
        var value = try LearningExplanationProtocol.decode(WordV2Fixture.induced, type: .word)
        value.synonyms = [.init(word: "cause", distinction: "")]
        #expect(throws: LearningError.self) { try value.validate(for: .word) }
        value.synonyms = Array(repeating: .init(word: "cause", distinction: "通用"), count: 5)
        #expect(throws: LearningError.self) { try value.validate(for: .word) }
    }
    @Test func partialWordAndSentenceRemainExcluded() throws {
        #expect(try !WordV2Fixture.selection("nduced").isLexicalExpression)
        #expect(try !WordV2Fixture.selection("The treatment induced changes.").isLexicalExpression)
    }
    @Test func schemasAreValidJSON() throws {
        for schema in [LearningExplanationProtocol.wordSchema, LearningExplanationProtocol.sentenceSchema] {
            let object = try #require(try JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any])
            #expect(object["additionalProperties"] as? Bool == false)
        }
    }
    @Test @MainActor func oldVocabularyReloadsAndV2ExtrasPersist() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let selection = try WordV2Fixture.selection()
        let store = ReaderLearningStore(directory: root)
        let value = try LearningExplanationProtocol.decode(WordV2Fixture.induced, type: .word)
        let entry = try store.save(selection: selection, explanation: value)
        #expect(ReaderLearningStore(directory: root).entries.first?.synonyms == value.synonyms)
        // Strip additions to mimic a genuine pre-v2 vocabulary file.
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        for key in ["partOfSpeech", "synonyms", "wordFamily", "collocations"] { object[key] = nil }
        try JSONSerialization.data(withJSONObject: ["version": 1, "entries": [object]]).write(to: root.appending(path: "vocabulary.json"))
        let reloaded = ReaderLearningStore(directory: root)
        #expect(reloaded.loadError == nil && reloaded.entries.count == 1)
        #expect(reloaded.entries[0].lemma == "induce" && reloaded.entries[0].synonyms == nil)
    }
    @Test @MainActor func legacyCacheCannotMasqueradeAsV2() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let key = LearningCacheKey(selection: try WordV2Fixture.selection(), type: .word, model: GeminiTranslator.Model.flashLite.rawValue)
        let old = try JSONSerialization.jsonObject(with: Data(WordV2Fixture.old.utf8))
        // Even an accidental matching digest in v1 must not be read by v2.
        let cache: [String: Any] = [key.digest: ["key": ["digest": key.digest], "value": old, "createdAt": 0]]
        try JSONSerialization.data(withJSONObject: cache).write(to: root.appending(path: "explanations-v1.json"))
        let store = ReaderLearningStore(directory: root)
        #expect(LearningCacheKey.promptVersion == 2 && store.cached(key, type: .word) == nil)
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "explanations-v1.json").path))
    }
    @Test @MainActor func phraseSavesAndDeduplicates() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReaderLearningStore(directory: root)
        let selection = try WordV2Fixture.selection("take into account", text: "We take into account the cost.")
        let value = try LearningExplanationProtocol.decode(WordV2Fixture.phrase, type: .word)
        try store.save(selection: selection, explanation: value)
        try store.save(selection: selection, explanation: value)
        #expect(store.entries.count == 1 && store.entries[0].word == "take into account")
    }
    @Test @MainActor func v2CacheHitSurvivesRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let selection = try WordV2Fixture.selection()
        let first = ReaderLearningController(store: ReaderLearningStore(directory: root), transport: LearningTransport { _,_,_ in WordV2Fixture.induced })
        await first.explain(selection, type: .word)
        #expect(first.result?.lemma == "induce")
        let second = ReaderLearningController(store: ReaderLearningStore(directory: root), transport: LearningTransport { _,_,_ in Issue.record("Unexpected request"); return "" })
        await second.explain(selection, type: .word)
        #expect(second.cacheHit && second.result?.synonyms?.count == 2)
    }
    @Test @MainActor func malformedV2CanRetryWithoutBadCache() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let selection = try WordV2Fixture.selection()
        let invalid = ReaderLearningController(store: ReaderLearningStore(directory: root), transport: LearningTransport { _,_,_ in "{}" })
        await invalid.explain(selection, type: .word)
        #expect(invalid.result == nil && invalid.message != nil)
        let retry = ReaderLearningController(store: ReaderLearningStore(directory: root), transport: LearningTransport { _,_,_ in WordV2Fixture.induced })
        await retry.explain(selection, type: .word)
        #expect(retry.result != nil && !retry.cacheHit)
    }
}
