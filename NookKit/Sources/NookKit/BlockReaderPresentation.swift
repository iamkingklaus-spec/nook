import Foundation

/// The renderer consumes this source-ordered tree, not a source column followed
/// by a translation column. Each group is one source/translation pair.
indirect enum BlockReaderPresentationNode {
    struct Group: Identifiable {
        let id: String
        let blockID: String
        let sourceHTML: String
        let translatedHTML: String?
        let heading: Int?
        func texts(in mode: BlockReaderMode) -> [Text] {
            var result: [Text] = []
            if mode != .chinese || translatedHTML == nil {
                result.append(Text(id: "source", html: sourceHTML, isTranslation: false))
            }
            if mode != .english, let translatedHTML {
                result.append(Text(id: "translation", html: translatedHTML, isTranslation: true))
            }
            return result
        }
    }
    struct Text: Identifiable, Equatable {
        let id: String
        let html: String
        let isTranslation: Bool
    }
    case group(Group)
    case quote([BlockReaderPresentationNode])
    case list(ordered: Bool, items: [[BlockReaderPresentationNode]])
    case unchanged(HTMLContentBlock)
}

enum BlockReaderPresentation {
    static let pairSpacing: CGFloat = 6
    static let groupSpacing: CGFloat = 19

    static func nodes(_ source: [BlockReaderNode], translations: [String: String],
                      templates: [String: String]) -> [BlockReaderPresentationNode] {
        source.flatMap { node -> [BlockReaderPresentationNode] in
            switch node {
            case .text(let id, let html, let heading):
                let text = BlockTranslationText(blockID: id, html: html)
                if let annotated = text.presentationHTML(translation: templates[id]),
                   let paragraphs = Paragraph.fragments(annotated.source), paragraphs.count > 1 {
                    let translated = annotated.translated.flatMap(Paragraph.fragments) ?? []
                    // A marker ID may occur only once. Unknown/malformed fragment
                    // structures cannot silently attach a translation elsewhere.
                    let allowed = Set(paragraphs.map(\.id))
                    let safe = Set(translated.map(\.id)).count == translated.count &&
                        translated.allSatisfy { allowed.contains($0.id) }
                    let byID = safe ? Dictionary(uniqueKeysWithValues: translated.map { ($0.id, $0.html) }) : [:]
                    return paragraphs.map { paragraph in
                        .group(.init(id: "\(id)/\(paragraph.id)", blockID: id, sourceHTML: paragraph.html,
                                     translatedHTML: nonempty(byID[paragraph.id]), heading: heading))
                    }
                }
                return [.group(.init(id: id, blockID: id, sourceHTML: html,
                                     translatedHTML: nonempty(translations[id]), heading: heading))]
            case .quote(let children):
                return [.quote(nodes(children, translations: translations, templates: templates))]
            case .list(let ordered, let items):
                return [.list(ordered: ordered, items: items.map { nodes($0, translations: translations, templates: templates) })]
            case .unchanged(let block): return [.unchanged(block)]
            }
        }
    }

    private static func nonempty(_ html: String?) -> String? {
        guard let html, !plainText(html).isEmpty else { return nil }
        return html
    }

    private static func plainText(_ html: String) -> String {
        HTMLContentParser.decodeEntities(html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct Paragraph {
        let id: String
        let html: String
        private struct Open {
            let name: String
            let start: Int
            let id: String
            var hasChild = false
        }
        private static let tags = try! NSRegularExpression(pattern: #"<\s*(/?)\s*(p|div|section|article)\b[^>]*>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators])
        private static let identity = try! NSRegularExpression(pattern: #" data-nook-presentation-id="([0-9]+)""#)

        /// Split only balanced, explicitly identified paragraph containers whose
        /// surrounding wrappers carry no extra prose. Inline markup stays intact.
        static func fragments(_ html: String) -> [Self]? {
            let source = html as NSString
            var stack: [Open] = []
            var leaves: [(range: NSRange, id: String)] = []
            for tag in tags.matches(in: html, range: NSRange(location: 0, length: source.length)) {
                let name = source.substring(with: tag.range(at: 2)).lowercased()
                if source.substring(with: tag.range(at: 1)) == "/" {
                    guard let open = stack.popLast(), open.name == name else { return nil }
                    if !open.hasChild {
                        leaves.append((NSRange(location: open.start, length: NSMaxRange(tag.range) - open.start), open.id))
                    }
                } else {
                    let raw = source.substring(with: tag.range)
                    guard let match = identity.firstMatch(in: raw, range: NSRange(location: 0, length: (raw as NSString).length)) else { return nil }
                    if !stack.isEmpty { stack[stack.count - 1].hasChild = true }
                    stack.append(Open(name: name, start: tag.range.location, id: (raw as NSString).substring(with: match.range(at: 1))))
                }
            }
            guard stack.isEmpty, !leaves.isEmpty, Set(leaves.map(\.id)).count == leaves.count else { return nil }
            leaves.sort { $0.range.location < $1.range.location }
            var remainder = html
            for leaf in leaves.reversed() {
                remainder = (remainder as NSString).replacingCharacters(in: leaf.range, with: "")
            }
            // Do not discard media, inline wrappers or text outside the leaves.
            let wrappersRemoved = tags.stringByReplacingMatches(in: remainder,
                range: NSRange(location: 0, length: (remainder as NSString).length), withTemplate: "")
            guard wrappersRemoved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return leaves.map { leaf in
                let fragment = source.substring(with: leaf.range)
                let clean = identity.stringByReplacingMatches(in: fragment,
                    range: NSRange(location: 0, length: (fragment as NSString).length), withTemplate: "")
                return Self(id: leaf.id, html: clean)
            }
        }
    }
}
