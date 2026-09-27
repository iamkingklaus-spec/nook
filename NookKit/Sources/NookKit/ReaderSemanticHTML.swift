import Foundation

/// Normalizes the bounded, sanitized HTML returned by the existing extractors.
/// This preserves HTML semantics; it does not decide which page is the article.
enum ReaderSemanticHTML {
    private indirect enum Node {
        case text(String)
        case element(name: String, open: String, children: [Node], close: String)
        var html: String {
            switch self {
            case .text(let text): return text
            case .element(_, let open, let children, let close): return open + children.map(\.html).joined() + close
            }
        }
        var name: String? { if case .element(let name, _, _, _) = self { return name }; return nil }
        var plain: String { ReaderHTMLSignals.plain(html) }
    }
    private struct Open { let name: String; let html: String; var children: [Node] }
    private static let wrappers: Set<String> = ["article", "section", "div", "aside", "main", "header", "footer"]
    private static let blocks: Set<String> = wrappers.union(["p", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "blockquote", "figure", "pre", "table", "img", "video", "audio", "iframe", "hr"])
    private static let voids: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"]

    static func normalize(_ html: String) -> String {
        guard html.utf8.count <= 2_000_000, let nodes = parse(html) else { return html }
        return flow(nodes)
    }

    private static func parse(_ html: String) -> [Node]? {
        let ns = html as NSString
        var stack: [Open] = [], roots: [Node] = [], cursor = 0
        func append(_ node: Node) {
            if stack.isEmpty { roots.append(node) } else { stack[stack.count - 1].children.append(node) }
        }
        for tag in ReaderHTMLSignals.tags.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            if tag.range.location > cursor { append(.text(ns.substring(with: NSRange(location: cursor, length: tag.range.location - cursor)))) }
            cursor = NSMaxRange(tag.range)
            guard tag.range(at: 1).location != NSNotFound else { continue }
            let raw = ns.substring(with: tag.range), name = ns.substring(with: tag.range(at: 1)).lowercased()
            if raw.hasPrefix("</") {
                guard let open = stack.popLast(), open.name == name else { return nil }
                append(.element(name: name, open: open.html, children: open.children, close: raw))
            } else if voids.contains(name) || raw.hasSuffix("/>") {
                append(.element(name: name, open: raw, children: [], close: ""))
            } else {
                guard stack.count < 64 else { return nil }
                stack.append(Open(name: name, html: raw, children: []))
            }
        }
        if cursor < ns.length { append(.text(ns.substring(from: cursor))) }
        return stack.isEmpty ? roots : nil
    }

    private static func authorGroup(_ node: Node) -> Bool {
        guard case .element(let name, _, let children, _) = node, wrappers.contains(name) || name == "span" else { return false }
        let visible = children.filter { !$0.plain.isEmpty }
        // Legibility strips BBC classes but retains adjacent span name/role pairs.
        return visible.count >= 2 && visible.allSatisfy { $0.name == "span" || $0.name == "a" || $0.name == "br" } &&
            visible.contains { TranslationEligibility.isAuthorRole($0.plain) } &&
            visible.contains { TranslationEligibility.isPersonName($0.plain) }
    }

    private static func inline(_ node: Node) -> String {
        guard case .element(let name, let open, let children, let close) = node else { return node.html }
        if authorGroup(node) {
            return "<span class=\"byline\">" + children.map(\.html).joined(separator: "<br>") + "</span>"
        }
        if name == "br" { return "<br>" }
        return open + children.map(inline).joined() + close
    }

    private static func explicitMetadata(_ node: Node) -> Bool {
        ReaderHTMLSignals.elements(node.html).contains {
            $0.range.location == 0 && TranslationEligibility.semantic($0) != nil
        }
    }

    private static func metadataAside(_ node: Node) -> Bool {
        guard node.name == "aside", node.plain.count < 300 else { return false }
        let elements = ReaderHTMLSignals.elements(node.html)
        guard !elements.contains(where: { ["p", "h1", "h2", "h3", "ul", "ol", "blockquote"].contains($0.name) }) else { return false }
        return elements.contains { element in
            TranslationEligibility.classify((node.html as NSString).substring(with: element.range)) == .publicationDate
        }
    }

    private static func flow(_ nodes: [Node]) -> String {
        var result = "", pending = ""
        func flush() {
            if !ReaderHTMLSignals.plain(pending).isEmpty || pending.contains("<img") {
                result += "<p>" + pending + "</p>\n"
            }
            pending = ""
        }
        for node in nodes {
            guard case .element(let name, let open, let children, let close) = node else { pending += node.html; continue }
            if wrappers.contains(name) {
                flush()
                if explicitMetadata(node) { result += node.html + "\n" }
                else if metadataAside(node) {
                    result += "<div class=\"byline\">" + flow(children) + "</div>\n"
                } else { result += authorGroup(node) ? "<p>" + inline(node) + "</p>\n" : flow(children) }
            } else if blocks.contains(name) {
                flush()
                if ["blockquote", "ul", "ol", "li"].contains(name) {
                    result += open + flow(children) + close + "\n"
                } else if name == "p", children.contains(where: { $0.name != nil && TranslationEligibility.classify($0.html) == .photoCredit }) {
                    // NPR's caption credit is a sibling bold/span with no space.
                    // Keep the caption and credit visible as separate text blocks.
                    var caption = ""
                    for child in children {
                        if child.name != nil && TranslationEligibility.classify(child.html) == .photoCredit {
                            if !ReaderHTMLSignals.plain(caption).isEmpty { result += open + caption + close + "\n" }
                            caption = ""
                            result += "<p><span class=\"photo-credit\">" + child.html + "</span></p>\n"
                        } else { caption += inline(child) }
                    }
                    if !ReaderHTMLSignals.plain(caption).isEmpty { result += open + caption + close + "\n" }
                } else {
                    // Preserve paragraph/heading, figure, code and table boundaries.
                    result += open + children.map(inline).joined() + close + "\n"
                }
            } else {
                if authorGroup(node) || explicitMetadata(node) {
                    flush()
                    result += "<p>" + inline(node) + "</p>\n"
                } else { pending += inline(node) }
            }
        }
        flush()
        return result
    }
}
