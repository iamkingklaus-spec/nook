import Foundation

enum TranslationEligibility: String, Sendable {
    case prose, photoCredit, author, publisher, publicationDate, numericMetadata, url, empty, code

    static func semantic(_ element: ReaderHTMLSignals.Element) -> Self? {
        let tokens = ReaderHTMLSignals.tokens(element.attributes)
        if !tokens.isDisjoint(with: ["photo-credit", "photograph-credit", "image-credit", "photographer"]) { return .photoCredit }
        if !tokens.isDisjoint(with: ["author", "byline", "article-author"]) || element.attributes["rel"] == "author" { return .author }
        if !tokens.isDisjoint(with: ["publisher", "publication-name"]) { return .publisher }
        if !tokens.isDisjoint(with: ["datepublished", "datemodified", "published-time", "publication-date"]) { return .publicationDate }
        return nil
    }

    static func classify(_ html: String, allowMetadata: Bool = true) -> Self {
        let text = ReaderHTMLSignals.plain(html)
        guard !text.isEmpty else { return .empty }
        if allowMetadata {
            for element in ReaderHTMLSignals.elements(html) {
                if let kind = semantic(element), ReaderHTMLSignals.plain((html as NSString).substring(with: element.range)) == text { return kind }
            }
            if text.range(of: #"(?i)^(?:photograph|photo(?:graph)? credit|image credit|photo):\s*\S.+$"#, options: .regularExpression) != nil { return .photoCredit }
            if text.range(of: #"^By [\p{Lu}][\p{L}’'.-]+(?: [\p{Lu}][\p{L}’'.-]+){1,4}$"#, options: .regularExpression) != nil { return .author }
            if text.range(of: #"^\d{4}-\d{2}-\d{2}(?:[T ][\d:.+Z-]+)?$"#, options: .regularExpression) != nil { return .publicationDate }
            if text.range(of: #"(?i)^(?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:tember)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\.? \d{1,2},? \d{4}$"#, options: .regularExpression) != nil { return .publicationDate }
        }
        if text.range(of: #"^(?:https?://|mailto:|www\.)\S+$"#, options: [.regularExpression, .caseInsensitive]) != nil { return .url }
        if text.range(of: #"^[\d\s.,:/%+−–—-]+$"#, options: .regularExpression) != nil { return .numericMetadata }
        return .prose
    }
}

enum BlockNormalizer {
    struct Result { let blocks: [HTMLContentBlock]; let reasons: [ArticleNoiseFilter.Reason] }

    static func normalize(_ blocks: [HTMLContentBlock], filterPhrases: Bool = true) -> Result {
        var output: [HTMLContentBlock] = []
        var reasons: [ArticleNoiseFilter.Reason] = []
        for original in blocks {
            var block = original
            switch original {
            case .text(let html):
                let cleaned = whitespace(html)
                let plain = ReaderHTMLSignals.plain(cleaned)
                if plain.isEmpty && !cleaned.contains("<") { reasons.append(.empty); continue }
                if plain.isEmpty && ReaderHTMLSignals.elements(cleaned).allSatisfy({ ["p", "div", "span", "em", "strong", "i", "b", "a", "small"].contains($0.name) }) &&
                    cleaned.range(of: #"<(?:img|br|hr|video|audio|iframe)\b"#, options: [.regularExpression, .caseInsensitive]) == nil {
                    reasons.append(.empty); continue
                }
                if filterPhrases,
                   cleaned.range(of: #"<(?:code|pre)\b"#, options: [.regularExpression, .caseInsensitive]) == nil,
                   let reason = ArticleNoiseFilter.standaloneReason(plain) { reasons.append(reason); continue }
                block = .text(cleaned)
                if filterPhrases, output.last == block { reasons.append(.duplicate); continue }
                if case .image(let media) = output.last, let caption = media.caption,
                   ReaderHTMLSignals.plain(caption) == plain { reasons.append(.duplicateCaption); continue }
            case .heading(let level, let html): block = .heading(level: level, html: whitespace(html))
            case .blockquote(let children):
                let result = normalize(children, filterPhrases: false)
                reasons += result.reasons; block = .blockquote(result.blocks)
            case .list(let ordered, let items):
                let results = items.map { normalize($0, filterPhrases: false) }
                reasons += results.flatMap(\.reasons)
                block = .list(ordered: ordered, items: results.map(\.blocks))
            default: break // Code, media and table contents are never rewritten.
            }
            output.append(block)
        }
        return Result(blocks: output, reasons: reasons)
    }

    static func whitespace(_ html: String) -> String {
        // Leave whitespace-sensitive inline code intact too.
        guard html.range(of: #"<(?:code|pre)\b"#, options: [.regularExpression, .caseInsensitive]) == nil else { return html }
        let ns = html as NSString
        let tags = ReaderHTMLSignals.tags.matches(in: html, range: NSRange(location: 0, length: ns.length))
        var result = "", cursor = 0
        for tag in tags {
            result += ns.substring(with: NSRange(location: cursor, length: tag.range.location - cursor))
                .replacingOccurrences(of: #"[\t\r\n ]+"#, with: " ", options: .regularExpression)
            result += ns.substring(with: tag.range)
            cursor = NSMaxRange(tag.range)
        }
        result += ns.substring(from: cursor).replacingOccurrences(of: #"[\t\r\n ]+"#, with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum ReaderBlockPreparation {
    struct Result { let blocks: [HTMLContentBlock]; let reasons: [ArticleNoiseFilter.Reason] }

    static func prepare(_ html: String, baseURL: URL?) -> Result {
        let filtered = ArticleNoiseFilter.filter(html)
        // Isolate explicitly identified metadata before the existing parser can
        // flatten it into neighbouring prose. This does not alter the RSS source.
        let ns = filtered.html as NSString
        let elements = ReaderHTMLSignals.elements(filtered.html)
        let metadata = elements.filter { candidate in
            !candidate.protected && TranslationEligibility.semantic(candidate) != nil &&
                !elements.contains { ancestor in
                    guard ancestor.range != candidate.range,
                          NSLocationInRange(candidate.range.location, ancestor.range) else { return false }
                    if ["ul", "ol", "figure", "h1", "h2", "h3", "h4", "h5", "h6"].contains(ancestor.name) { return true }
                    // An inline author link in a real sentence is not a byline.
                    return ancestor.name == "p" && ReaderHTMLSignals.plain(ns.substring(with: ancestor.range)) !=
                        ReaderHTMLSignals.plain(ns.substring(with: candidate.range))
                }
        }.sorted { $0.range.location < $1.range.location }
        var blocks: [HTMLContentBlock] = [], cursor = 0
        for element in metadata where element.range.location >= cursor {
            let prefix = ns.substring(with: NSRange(location: cursor, length: element.range.location - cursor))
            blocks += HTMLContentParser.parse(prefix, baseURL: baseURL)
            blocks.append(.text(ns.substring(with: element.range)))
            cursor = NSMaxRange(element.range)
        }
        blocks += HTMLContentParser.parse(ns.substring(from: cursor), baseURL: baseURL)
        return Result(blocks: blocks, reasons: filtered.reasons)
    }
}
