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
}

struct BlockReaderDocument: Sendable {
    let document: ArticleDocument
    let nodes: [BlockReaderNode]
    let texts: [BlockTranslationText]

    init(input: BlockReaderInput) {
        let parsed = input.html.map { HTMLContentParser.parse($0, baseURL: input.url) }
            ?? input.paragraphs.map { HTMLContentBlock.text(BlockTranslationText.escape($0)) }
        self.init(blocks: parsed, source: input.source, baseURL: input.url)
    }

    init(blocks: [HTMLContentBlock], source: ArticleContentSource, baseURL: URL?) {
        var builder = Builder(baseURL: baseURL)
        nodes = builder.build(blocks)
        document = ArticleDocument(source: source, blocks: builder.blocks)
        texts = builder.texts
    }

    private struct Builder {
        let baseURL: URL?
        var blocks: [ArticleBlock] = []
        var texts: [BlockTranslationText] = []
        var occurrences: [String: Int] = [:]

        mutating func append(_ kind: ArticleBlock.Kind, _ content: String) -> ArticleBlock {
            let prototype = ArticleBlock(kind: kind, sourceContent: content, format: .html)
            let occurrence = occurrences[prototype.contentHash, default: 0]
            occurrences[prototype.contentHash] = occurrence + 1
            let block = ArticleBlock(kind: kind, sourceContent: content, format: .html, occurrence: occurrence)
            blocks.append(block)
            return block
        }

        mutating func text(_ html: String, kind: ArticleBlock.Kind, heading: Int? = nil) -> BlockReaderNode {
            let block = append(kind, html)
            let text = BlockTranslationText(blockID: block.id, html: html)
            if text.hasProse { texts.append(text) }
            return .text(id: block.id, html: html, heading: heading)
        }

        mutating func build(_ originals: [HTMLContentBlock], kind: ArticleBlock.Kind = .paragraph) -> [BlockReaderNode] {
            originals.flatMap { block -> [BlockReaderNode] in
                switch block {
                case .text(let html):
                    return [text(html, kind: kind)]
                case .heading(let level, let html):
                    // Heading level is structure, so include it in the document identity.
                    _ = append(.other, "heading:\(level)")
                    return [text(html, kind: .heading, heading: level)]
                case .blockquote(let children):
                    _ = append(.other, "quote:open")
                    let nodes = build(children, kind: .quote)
                    _ = append(.other, "quote:close")
                    return [.quote(nodes)]
                case .list(let ordered, let items):
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
                    _ = append(.image, ArticleMarkdown.render([block], baseURL: baseURL))
                    guard let caption = media.caption, !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        return [.unchanged(block)]
                    }
                    let picture = HTMLMedia(url: media.url, title: media.title, caption: nil,
                                            posterURL: media.posterURL, aspectRatio: media.aspectRatio,
                                            declaredWidth: media.declaredWidth)
                    return [.unchanged(.image(picture)), text(BlockTranslationText.escape(caption), kind: .paragraph)]
                default:
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
/// literal URLs are opaque too. A damaged marker rejects the entire batch.
struct BlockTranslationText: Sendable {
    let blockID: String
    let template: String
    private let markedHTML: String
    private let protected: [String: String]

    init(blockID: String, html: String) {
        self.blockID = blockID
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
            throw BlockTranslationError.empty(blockID)
        }
        var remaining = translation
        for token in protected.keys {
            guard remaining.components(separatedBy: token).count == 2 else {
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
            throw BlockTranslationError.empty(blockID)
        }
        guard !withoutMarkers.contains("⟦"), !withoutMarkers.contains("⟧"),
              withoutMarkers.range(of: "(?:https?://|mailto:|www\\.)", options: [.regularExpression, .caseInsensitive]) == nil else {
            throw BlockTranslationError.markup(blockID)
        }
        guard !remaining.contains("⟬"), !remaining.contains("⟭"),
              var html = InlineMarkupTranslator.rebuild(translation, entries: InlineMarkupTranslator.markify(markedHTML).entries)
        else { throw BlockTranslationError.markup(blockID) }
        for (token, original) in protected { html = html.replacingOccurrences(of: token, with: original) }
        return html
    }

    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
