import Foundation

enum LiveEntryMetadata {
    enum Kind: Equatable { case relativeTime, absoluteTime, sourceLabel }
    static func isGuardianLive(_ url: URL?) -> Bool {
        let host = url?.host?.lowercased() ?? ""
        return (host == "theguardian.com" || host.hasSuffix(".theguardian.com")) && url?.path.contains("/live/") == true
    }
    static func isChrome(_ element: ReaderHTMLSignals.Element, descendants: [ReaderHTMLSignals.Element], source: NSString) -> Bool {
        guard ["div", "header", "span", "time"].contains(element.name), element.range.length < 2000 else { return false }
        let labels = descendants.filter { candidate in
            ["span", "time", "a"].contains(candidate.name) && kind(ReaderHTMLSignals.plain(source.substring(with: candidate.range))) != nil
        }
        let kinds = labels.compactMap { kind(ReaderHTMLSignals.plain(source.substring(with: $0.range))) }
        guard kinds.contains(.relativeTime) && kinds.contains(.absoluteTime) else { return false }
        let outer = labels.filter { label in
            !labels.contains { $0.range != label.range && NSLocationInRange(label.range.location, $0.range) }
        }
        var remainder = source.substring(with: element.range)
        for label in outer.sorted(by: { $0.range.location > $1.range.location }) {
            remainder = (remainder as NSString).replacingCharacters(in: NSRange(location: label.range.location - element.range.location, length: label.range.length), with: "")
        }
        let plain = ReaderHTMLSignals.plain(remainder)
        return plain.isEmpty || plain == "From"
    }
    static func kind(_ text: String) -> Kind? {
        if text.range(of: #"(?i)^\d{1,3}\s*(?:h|m|s|hours?|minutes?|seconds?)(?:\s+\d{1,2}\s*m)?\s+ago$"#, options: .regularExpression) != nil { return .relativeTime }
        if text.range(of: #"^\d{1,2}[.:]\d{2}\s+(?:BST|GMT|UTC|EST|EDT|CST|CDT|MST|MDT|PST|PDT|CET|CEST)$"#, options: .regularExpression) != nil { return .absoluteTime }
        if text == "From" { return .sourceLabel }
        return nil
    }
}

/// Local presentation metadata, deliberately outside ArticleDocument and its
/// translation/cache identity. The image URL associates a credit when known.
struct ReaderPhotoCredit: Sendable {
    let text: String
    let imageURL: URL?

    static func splitCaption(_ caption: String) -> (caption: String?, credit: String?) {
        if TranslationEligibility.classify(caption) == .photoCredit { return (nil, ReaderHTMLSignals.plain(caption)) }
        guard let range = caption.range(of: #"(?i)\s+(?:Photograph|Photo(?:graph)? credit|Image credit|Photo):\s*"#, options: .regularExpression) else { return (caption, nil) }
        return (String(caption[..<range.lowerBound]), String(caption[range.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

enum ReaderAuxiliaryMetadata {
    struct Result { let blocks: [HTMLContentBlock]; let reasons: [ArticleNoiseFilter.Reason] }

    static func clean(_ blocks: [HTMLContentBlock], sourceURL: URL?) -> Result {
        let host = sourceURL?.host?.lowercased() ?? ""
        let guardian = host == "theguardian.com" || host.hasSuffix(".theguardian.com")
        let live = LiveEntryMetadata.isGuardianLive(sourceURL)
        var removed = Set<Int>(), reasons: [ArticleNoiseFilter.Reason] = []
        func plain(_ index: Int) -> String? {
            guard blocks.indices.contains(index), case .text(let html) = blocks[index] else { return nil }
            return ReaderHTMLSignals.plain(html)
        }
        func time(_ index: Int) -> Bool {
            guard let value = plain(index), let kind = LiveEntryMetadata.kind(value) else { return false }
            return kind != .sourceLabel
        }
        for index in blocks.indices {
            if live, let text = plain(index) {
                let adjacentTime = [index - 1, index + 1].contains(where: time)
                let temporal = time(index)
                let source = text == "From" || (text.hasPrefix("From ") && TranslationEligibility.isPersonName(String(text.dropFirst(5))))
                // Isolated words/numbers are not evidence; require the adjacent
                // relative/absolute timestamp pair, or a source label + time.
                if (temporal && (adjacentTime || plain(index - 1) == "From" || plain(index + 1) == "From")) || (source && adjacentTime) {
                    removed.insert(index); reasons.append(.liveEntryMetadata)
                }
            }
            // Classless Guardian cards may be split into sibling title/CTA
            // blocks. Require the entire title to be a link to another article.
            if guardian, index + 1 < blocks.count, plain(index + 1)?.lowercased() == "read more",
               case .text(let html) = blocks[index], ArticleTailBoundary.linksOnly(html) {
                let links = ReaderHTMLSignals.elements(html).filter { $0.name == "a" }
                let urls = Set(links.compactMap { $0.attributes["href"].flatMap { URL(string: $0, relativeTo: sourceURL)?.absoluteURL } })
                if urls.count == 1, let url = urls.first,
                   url.host == sourceURL?.host, url.path != sourceURL?.path {
                    removed.formUnion([index, index + 1]); reasons.append(.relatedContent)
                }
            }
        }
        return Result(blocks: blocks.enumerated().filter { !removed.contains($0.offset) }.map(\.element), reasons: reasons)
    }
}
