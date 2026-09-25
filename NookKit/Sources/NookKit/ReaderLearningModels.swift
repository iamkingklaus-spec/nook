import Foundation

public struct LearningArticleContext: Equatable, Sendable {
    public let articleID: String
    public let articleURL: URL
    public let title: String
    public let publisher: String
    public init(articleID: String, articleURL: URL, title: String, publisher: String) {
        self.articleID = articleID; self.articleURL = articleURL
        self.title = title; self.publisher = publisher
    }
}

enum LearningExplanationType: String, Codable, Sendable { case word, sentence }
enum LearningTextOrigin { case source, translation }

/// Selection offsets refer to the rendered SOURCE leaf, never translated text or
/// a document-wide substring search (which confuses repeated words/paragraphs).
struct LearningSelection: Equatable, Sendable {
    let article: LearningArticleContext
    let documentHash: String
    let blockID: String
    let selectedText: String
    let sentence: String
    let blockContext: String
    let offset: Int
    let hasWordBoundaries: Bool

    var isWord: Bool {
        hasWordBoundaries && selectedText.range(of: #"^[A-Za-z]+(?:['’\-][A-Za-z]+)*$"#, options: .regularExpression) != nil
            && selectedText.count <= 80
    }

    static func resolve(article: LearningArticleContext, document: ArticleDocument,
                        blockID: String, renderedSource: String, range: NSRange,
                        origin: LearningTextOrigin = .source) -> Self? {
        guard origin == .source,
              let block = document.blocks.first(where: { $0.id == blockID }),
              [.paragraph, .heading, .quote, .listItem].contains(block.kind),
              range.location >= 0, range.location <= renderedSource.utf16.count,
              range.length > 0, range.length <= renderedSource.utf16.count - range.location,
              let selectedRange = Range(range, in: renderedSource) else { return nil }
        let selected = String(renderedSource[selectedRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selected.isEmpty, selected.count <= 1200,
              selected.range(of: "[A-Za-z]", options: .regularExpression) != nil,
              selected.range(of: "[\\p{Han}\\p{Hiragana}\\p{Katakana}]", options: .regularExpression) == nil else { return nil }
        var sentenceRange = selectedRange
        renderedSource.enumerateSubstrings(in: renderedSource.startIndex..., options: [.bySentences, .substringNotRequired]) { _, r, _, _ in
            if r.overlaps(selectedRange) {
                sentenceRange = min(sentenceRange.lowerBound, r.lowerBound)..<max(sentenceRange.upperBound, r.upperBound)
            }
        }
        // Bound even pathological one-paragraph articles. No whole-article input.
        func window(_ range: Range<String.Index>, margin: Int) -> String {
            let lower = renderedSource.index(range.lowerBound, offsetBy: -margin, limitedBy: renderedSource.startIndex) ?? renderedSource.startIndex
            let upper = renderedSource.index(range.upperBound, offsetBy: margin, limitedBy: renderedSource.endIndex) ?? renderedSource.endIndex
            return String(renderedSource[lower..<upper]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let sentence = renderedSource[sentenceRange].count <= 1400
            ? String(renderedSource[sentenceRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            : window(selectedRange, margin: 100)
        let wordRange = renderedSource.range(of: selected, range: selectedRange) ?? selectedRange
        func wordCharacter(_ character: Character) -> Bool {
            String(character).range(of: #"[A-Za-z'’\-]"#, options: .regularExpression) != nil
        }
        let leftBoundary = wordRange.lowerBound == renderedSource.startIndex ||
            !wordCharacter(renderedSource[renderedSource.index(before: wordRange.lowerBound)])
        let rightBoundary = wordRange.upperBound == renderedSource.endIndex ||
            !wordCharacter(renderedSource[wordRange.upperBound])
        return Self(article: article, documentHash: document.documentHash, blockID: blockID,
                    selectedText: selected, sentence: sentence,
                    blockContext: window(selectedRange, margin: 1000), offset: range.location,
                    hasWordBoundaries: leftBoundary && rightBoundary)
    }
}

struct LearningExplanation: Codable, Equatable, Sendable {
    let type: LearningExplanationType
    let meaning: String
    var lemma: String? = nil
    var englishDefinition: String? = nil
    var usage: String? = nil
    var example: String? = nil
    var mainClause: String? = nil
    var grammar: [String]? = nil
    var phrases: [String]? = nil
    var pitfalls: [String]? = nil

    func validate(for type: LearningExplanationType) throws {
        func text(_ value: String?, required: Bool = false) -> Bool {
            guard let value else { return !required }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= 1600
        }
        guard self.type == type, text(meaning, required: true) else { throw LearningError.malformed }
        switch type {
        case .word:
            guard text(lemma, required: true), (lemma?.count ?? 0) <= 100,
                  text(englishDefinition, required: true), text(usage, required: true), text(example),
                  mainClause == nil, grammar == nil, phrases == nil, pitfalls == nil else { throw LearningError.malformed }
        case .sentence:
            guard text(mainClause, required: true), lemma == nil, englishDefinition == nil, usage == nil, example == nil else { throw LearningError.malformed }
            for values in [grammar, phrases, pitfalls] {
                guard let values, values.count <= 5, values.allSatisfy({ text($0, required: true) }) else { throw LearningError.malformed }
            }
        }
    }
}

enum LearningError: Error { case malformed, storage, unsupportedVersion }

struct LearningCacheKey: Codable, Equatable, Sendable {
    static let promptVersion = 1
    let digest: String
    init(selection: LearningSelection, type: LearningExplanationType, model: String) {
        digest = ArticleDocument.digest(["learning", "gemini", "zh-Hans", String(Self.promptVersion),
            String(ArticleDocument.currentSchemaVersion), selection.article.articleID,
            selection.article.articleURL.absoluteString, selection.documentHash, selection.blockID,
            selection.selectedText, String(selection.offset), selection.sentence, selection.blockContext,
            String(selection.article.title.prefix(200)), type.rawValue, model])
    }
}

public struct VocabularyEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let word: String
    public let lemma: String
    public let meaning: String
    public let originalSentence: String
    public let articleTitle: String
    public let publisher: String
    public let articleURL: URL
    public let articleID: String
    public let documentHash: String
    public let blockID: String
    public let createdAt: Date

    init(selection: LearningSelection, explanation: LearningExplanation, createdAt: Date = .now) {
        word = selection.selectedText; lemma = explanation.lemma ?? word
        meaning = explanation.meaning; originalSentence = selection.sentence
        articleTitle = selection.article.title; publisher = selection.article.publisher
        articleURL = selection.article.articleURL; articleID = selection.article.articleID
        documentHash = selection.documentHash; blockID = selection.blockID
        self.createdAt = createdAt
        // Same word in the same source sentence is one entry, even after a
        // document refresh. A distinct context intentionally remains distinct.
        id = ArticleDocument.digest([word.lowercased(), originalSentence, articleURL.absoluteString])
    }
}
