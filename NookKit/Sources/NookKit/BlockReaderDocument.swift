import Foundation

/// The exact body currently displayed by the reader. A new extraction is a new
/// input, even when the article URL has not changed. No library migration needed.
public struct BlockReaderInput: Equatable, Sendable {
    public let articleID: String
    public let url: URL
    public let html: String?
    public let paragraphs: [String]
    public let source: ArticleContentSource

    public init(articleID: String, url: URL, html: String?, paragraphs: [String],
                source: ArticleContentSource) {
        self.articleID = articleID
        self.url = url
        self.html = html
        self.paragraphs = paragraphs
        self.source = source
    }
}

/// Render topology stays on the client. The model only sees eligible text leaves.
indirect enum BlockReaderNode: Sendable {
    case text(id: String, html: String, heading: Int?)
    case quote([BlockReaderNode])
    case list(ordered: Bool, items: [[BlockReaderNode]])
    case unchanged(HTMLContentBlock)
    case photoCredit(ReaderPhotoCredit)
}

struct BlockReaderDocument: Sendable {
    let document: ArticleDocument
    let nodes: [BlockReaderNode]
    let texts: [BlockTranslationText]
    let preparationReasons: [ArticleNoiseFilter.Reason]
    let eligibility: [String: TranslationEligibility]

    func withBaseline(_ baseline: ArticleDocument) -> Self {
        guard baseline == document else { return self }
        return Self(document: baseline, nodes: nodes, texts: texts,
                    preparationReasons: preparationReasons, eligibility: eligibility)
    }

    /// Preserve source identity for learning, cache matching and Original Website.
    /// AI cleanup only masks display/translation candidates; it never rewrites it.
    func presentationCopy(nodes: [BlockReaderNode], texts: [BlockTranslationText]) -> Self {
        Self(document: document, nodes: nodes, texts: texts,
             preparationReasons: preparationReasons, eligibility: eligibility)
    }

    private init(document: ArticleDocument, nodes: [BlockReaderNode], texts: [BlockTranslationText],
                 preparationReasons: [ArticleNoiseFilter.Reason], eligibility: [String: TranslationEligibility]) {
        self.document = document
        self.nodes = nodes
        self.texts = texts
        self.preparationReasons = preparationReasons
        self.eligibility = eligibility
    }

    init(input: BlockReaderInput) {
        let prepared = input.html.map { ReaderBlockPreparation.prepare($0, baseURL: input.url) }
        let parsed = prepared?.blocks ?? input.paragraphs.map { HTMLContentBlock.text(BlockTranslationText.escape($0)) }
        self.init(blocks: parsed, source: input.source, baseURL: input.url, reasons: prepared?.reasons ?? [])
    }

    init(blocks: [HTMLContentBlock], source: ArticleContentSource, baseURL: URL?, reasons: [ArticleNoiseFilter.Reason] = []) {
        let normalized = BlockNormalizer.normalize(blocks)
        var builder = Builder(baseURL: baseURL)
        nodes = builder.build(normalized.blocks)
        document = ArticleDocument(source: source, blocks: builder.blocks)
        texts = builder.texts
        preparationReasons = reasons + normalized.reasons
        eligibility = builder.eligibility
    }

    private struct Builder {
        let baseURL: URL?
        var blocks: [ArticleBlock] = []
        var texts: [BlockTranslationText] = []
        var occurrences: [String: Int] = [:]
        var eligibility: [String: TranslationEligibility] = [:]

        mutating func append(_ kind: ArticleBlock.Kind, _ content: String) -> ArticleBlock {
            let prototype = ArticleBlock(kind: kind, sourceContent: content, format: .html)
            let occurrence = occurrences[prototype.contentHash, default: 0]
            occurrences[prototype.contentHash] = occurrence + 1
            let block = ArticleBlock(kind: kind, sourceContent: content, format: .html, occurrence: occurrence)
            blocks.append(block)
            return block
        }

        mutating func text(_ html: String, kind: ArticleBlock.Kind, heading: Int? = nil, imageURL: URL? = nil) -> BlockReaderNode {
            let allowed = TranslationEligibility.classify(html, allowMetadata: kind == .paragraph)
            if allowed == .photoCredit {
                return .photoCredit(ReaderPhotoCredit(text: ReaderHTMLSignals.plain(html), imageURL: imageURL))
            }
            let block = append(allowed == .prose ? kind : .other, html)
            let text = BlockTranslationText(blockID: block.id, html: html, kind: kind)
            eligibility[block.id] = allowed == .prose && !text.hasProse ? .code : allowed
            if allowed == .prose && text.hasProse { texts.append(text) }
            return .text(id: block.id, html: html, heading: heading)
        }

        mutating func build(_ originals: [HTMLContentBlock], kind: ArticleBlock.Kind = .paragraph) -> [BlockReaderNode] {
            var precedingImage: URL?
            return originals.flatMap { block -> [BlockReaderNode] in
                switch block {
                case .text(let html):
                    let associatedImage = precedingImage
                    if TranslationEligibility.classify(html) != .photoCredit { precedingImage = nil }
                    return [text(html, kind: kind, imageURL: associatedImage)]
                case .heading(let level, let html):
                    precedingImage = nil
                    // Heading level is structure, so include it in the document identity.
                    _ = append(.other, "heading:\(level)")
                    return [text(html, kind: .heading, heading: level)]
                case .blockquote(let children):
                    precedingImage = nil
                    _ = append(.other, "quote:open")
                    let nodes = build(children, kind: .quote)
                    _ = append(.other, "quote:close")
                    return [.quote(nodes)]
                case .list(let ordered, let items):
                    precedingImage = nil
                    _ = append(.other, "list:\(ordered):open")
                    let nodes = items.map { item in
                        _ = append(.other, "item:open")
                        let nodes = build(item, kind: .listItem)
                        _ = append(.other, "item:close")
                        return nodes
                    }
                    _ = append(.other, "list:close")
                    return [.list(ordered: ordered, items: nodes)]
                case .image(let media):
                    precedingImage = media.url
                    let parts = media.caption.map(ReaderPhotoCredit.splitCaption)
                    let identityImage = HTMLMedia(url: media.url, title: media.title, caption: parts?.caption,
                        posterURL: media.posterURL, aspectRatio: media.aspectRatio, declaredWidth: media.declaredWidth)
                    _ = append(.image, ArticleMarkdown.render([.image(identityImage)], baseURL: baseURL))
                    guard let caption = media.caption, !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        return [.unchanged(block)]
                    }
                    let picture = HTMLMedia(url: media.url, title: media.title, caption: nil,
                                            posterURL: media.posterURL, aspectRatio: media.aspectRatio,
                                            declaredWidth: media.declaredWidth)
                    var nodes: [BlockReaderNode] = [.unchanged(.image(picture))]
                    if let caption = parts?.caption, !caption.isEmpty { nodes.append(text(BlockTranslationText.escape(caption), kind: .paragraph)) }
                    if let credit = parts?.credit { nodes.append(.photoCredit(.init(text: credit, imageURL: media.url))) }
                    return nodes
                default:
                    precedingImage = nil
                    // Code, tables and all media retain their original native renderer.
                    // Their contents participate in identity but never go to Gemini.
                    _ = append(.other, ArticleMarkdown.render([block], baseURL: baseURL))
                    return [.unchanged(block)]
                }
            }
        }
    }
}

/// Inline attributes (including href) never leave the client. Inline code and
/// literal URLs are opaque too. The legacy validator rejects damaged markers per block.
struct BlockTranslationText: Sendable {
    let blockID: String
    let template: String
    let kind: ArticleBlock.Kind
    private let sourceHTML: String
    private let markedHTML: String
    private let protected: [String: String]

    init(blockID: String, html: String, kind: ArticleBlock.Kind = .paragraph) {
        self.blockID = blockID
        self.kind = kind
        self.sourceHTML = html
        let prefix = "⟬nook:\(ArticleDocument.digest([html]).prefix(16)):"
        var protected: [String: String] = [:]
        func replace(_ source: String, pattern: String, escape: Bool) -> String {
            let regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
            let ns = source as NSString
            var result = source
            for match in regex.matches(in: source, range: NSRange(location: 0, length: ns.length)).reversed() {
                let token = "\(prefix)\(protected.count)⟭"
                let original = ns.substring(with: match.range)
                protected[token] = escape ? Self.escape(original) : original
                result = (result as NSString).replacingCharacters(in: match.range, with: token)
            }
            return result
        }
        markedHTML = replace(html, pattern: "<code\\b[^>]*>.*?</code\\s*>", escape: false)
        let marked = InlineMarkupTranslator.markify(markedHTML)
        template = replace(marked.template, pattern: "(?:https?://|mailto:|www\\.)[^\\s<>⟦⟧⟬⟭]+", escape: true)
        self.protected = protected
    }

    var hasProse: Bool {
        var value = template
        for token in protected.keys { value = value.replacingOccurrences(of: token, with: "") }
        return !InlineMarkupTranslator.stripMarkers(value).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Presentation-only identities reuse the exact tag-marker IDs that were
    /// already sent and validated. Keep original block IDs and cached templates;
    /// never infer paragraph correspondence from translated array/DOM order.
    func presentationHTML(translation: String?) -> (source: String, translated: String?)? {
        guard !markedHTML.localizedCaseInsensitiveContains("data-nook-presentation-id") else { return nil }
        let entries = InlineMarkupTranslator.markify(markedHTML).entries.enumerated().map { index, entry in
            guard !entry.opaque, ["p", "div", "section", "article"].contains(entry.name),
                  let end = entry.raw.lastIndex(of: ">") else { return entry }
            let raw = String(entry.raw[..<end]) + " data-nook-presentation-id=\"\(index)\">"
            return InlineMarkupTranslator.Entry(raw: raw, name: entry.name, opaque: false)
        }
        func rebuild(_ value: String) -> String? {
            guard var html = InlineMarkupTranslator.rebuild(value, entries: entries) else { return nil }
            for (token, original) in protected { html = html.replacingOccurrences(of: token, with: original) }
            return html
        }
        guard let source = rebuild(template) else { return nil }
        return (source, translation.flatMap(rebuild))
    }

    func restore(_ translation: String) throws -> String {
        guard !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            recordValidationFailure(rule: "emptyTranslation", response: translation)
            throw BlockTranslationError.empty(blockID)
        }
        var remaining = translation
        for token in protected.keys {
            guard remaining.components(separatedBy: token).count == 2 else {
                recordValidationFailure(rule: "protectedSpanCount:\(token)", response: translation)
                throw BlockTranslationError.markup(blockID)
            }
            remaining = remaining.replacingOccurrences(of: token, with: "")
        }
        // Reject stray or invented markers rather than relying on a permissive
        // prose fallback. URLs appear only inside protected placeholders.
        let inlineMarkers = try! NSRegularExpression(pattern: "⟦(?:=|/)?[0-9]+⟧")
        let withoutMarkers = inlineMarkers.stringByReplacingMatches(in: remaining,
            range: NSRange(remaining.startIndex..., in: remaining), withTemplate: "")
        guard !withoutMarkers.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            recordValidationFailure(rule: "emptyProse", response: translation)
            throw BlockTranslationError.empty(blockID)
        }
        guard !withoutMarkers.contains("⟦"), !withoutMarkers.contains("⟧"),
              withoutMarkers.range(of: "(?:https?://|mailto:|www\\.)", options: [.regularExpression, .caseInsensitive]) == nil else {
            recordValidationFailure(rule: "strayMarkerOrInventedURL", response: translation)
            throw BlockTranslationError.markup(blockID)
        }
        guard !remaining.contains("⟬"), !remaining.contains("⟭"),
              var html = InlineMarkupTranslator.rebuild(translation, entries: InlineMarkupTranslator.markify(markedHTML).entries)
        else {
            recordValidationFailure(rule: inlineFailureRule(translation) ?? "unknownProtectedSpan", response: translation)
            throw BlockTranslationError.markup(blockID)
        }
        for (token, original) in protected { html = html.replacingOccurrences(of: token, with: original) }
        return html
    }

    /// Identifies the exact legacy marker invariant without changing its repair
    /// behavior. Available to offline regression tests as well as DEBUG logs.
    func inlineFailureRule(_ translation: String) -> String? {
        let entries = InlineMarkupTranslator.markify(markedHTML).entries
        let value = InlineMarkupTranslator.normalizeMarkers(translation) as NSString
        let regex = try! NSRegularExpression(pattern: #"⟦(=|/)?([0-9]+)⟧"#)
        var stack: [Int] = [], seen = Set<Int>()
        for match in regex.matches(in: value as String, range: NSRange(location: 0, length: value.length)) {
            let kind = match.range(at: 1).location == NSNotFound ? "" : value.substring(with: match.range(at: 1))
            guard let index = Int(value.substring(with: match.range(at: 2))), entries.indices.contains(index) else { return "unknownInlineMarker" }
            if kind == "/" {
                guard stack.popLast() == index else { return "misnestedClosingMarker:\(index)" }
            } else {
                guard !seen.contains(index) else { return "duplicateInlineMarker:\(index)" }
                guard entries[index].opaque == (kind == "=") else { return "wrongMarkerKind:\(index)" }
                seen.insert(index)
                if kind != "=" { stack.append(index) }
            }
        }
        if let index = stack.last { return "unclosedInlineMarker:\(index)" }
        if let index = entries.indices.first(where: { !seen.contains($0) }) { return "missingInlineMarker:\(index)" }
        return nil
    }

    func recordValidationFailure(rule: String, response: String) {
        #if DEBUG
        // Explicit diagnostic switch: no full article or credentials by default.
        // The provider key is never part of this object or its response payload.
        guard UserDefaults.standard.bool(forKey: "readerTranslationValidationDiagnostics") else { return }
        let report: [String: Any] = ["blockID": blockID, "kind": kind.rawValue, "rule": rule,
            "sourceInlineStructure": sourceHTML, "protectedSpans": protected,
            "inlineTags": InlineMarkupTranslator.markify(markedHTML).entries.map(\.raw), "response": response]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) { print("[BlockValidation] " + json) }
        #endif
    }

    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
