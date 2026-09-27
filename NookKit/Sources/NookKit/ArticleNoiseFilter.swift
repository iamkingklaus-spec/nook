import Foundation

/// A conservative pass over already-extracted HTML, not another article parser.
/// Only explicitly closed containers are considered; uncertain markup survives.
enum ArticleNoiseFilter {
    enum Reason: String, Sendable {
        case semanticAdvertisement, navigation, newsletterPromotion, subscriptionPromotion
        case relatedContent, socialTools, appPromotion, privacyPrompt, footer
        case contactModule, tailBoundary
        case liveEntryMetadata
        case empty, duplicate, duplicateCaption
    }
    struct Result: Sendable {
        let html: String
        let reasons: [Reason]
    }

    static func filter(_ html: String, sourceURL: URL? = nil) -> Result {
        let elements = ReaderHTMLSignals.elements(html)
        let ns = html as NSString
        var removed: [NSRange] = []
        var reasons: [Reason] = []
        for element in elements.sorted(by: { $0.range.location < $1.range.location }) {
            guard !removed.contains(where: { NSLocationInRange(element.range.location, $0) }),
                  !element.protected,
                  !elements.contains(where: { ["blockquote", "pre", "code"].contains($0.name) && NSLocationInRange($0.range.location, element.range) }) else { continue }
            let text = ReaderHTMLSignals.plain(ns.substring(with: element.range))
            // Legibility deliberately strips class/id. A topic-footer label plus
            // a link list is still explicit structure; article paragraphs veto it.
            let descendants = elements.filter { $0.range != element.range && NSLocationInRange($0.range.location, element.range) }
            let inlineSentence = elements.contains { ancestor in
                ancestor.name == "p" && ancestor.range != element.range &&
                    NSLocationInRange(element.range.location, ancestor.range) &&
                    ReaderHTMLSignals.plain(ns.substring(with: ancestor.range)) != text
            }
            if !inlineSentence, isRelatedCard(element, descendants: descendants, source: ns) {
                removed.append(element.range); reasons.append(.relatedContent); continue
            }
            if LiveEntryMetadata.isGuardianLive(sourceURL),
               LiveEntryMetadata.isChrome(element, descendants: descendants, source: ns) {
                removed.append(element.range); reasons.append(.liveEntryMetadata); continue
            }
            let tokens = ReaderHTMLSignals.tokens(element.attributes)
            let liveTokens: Set<String> = ["live-entry-meta", "live-entry-metadata", "entry-meta", "block-time",
                "block-time-published", "block-relative-time", "liveblog-timestamp", "live-entry-author"]
            if text.count < 300, !tokens.isDisjoint(with: liveTokens) ||
                liveTokens.contains(element.attributes["data-component"] ?? "") {
                removed.append(element.range); reasons.append(.liveEntryMetadata); continue
            }
            // Explicit semantic modules can appear before, between, or after
            // article paragraphs. An aside alone is not sufficient evidence.
            if ["aside", "footer"].contains(element.name),
               descendants.contains(where: { ["a", "form"].contains($0.name) }),
               let heading = descendants.first(where: { ["h2", "h3", "h4"].contains($0.name) }),
               let reason = ArticleTailBoundary.marker(ReaderHTMLSignals.plain(ns.substring(with: heading.range))) {
                removed.append(element.range); reasons.append(reason); continue
            }
            let topicLabel = ["Explore more on these topics", "Related topics", "More on this story"]
                .contains { text.hasPrefix($0 + " ") }
            let hasBodyParagraph = descendants.contains { paragraph in
                paragraph.name == "p" && !descendants.contains { link in
                    link.name == "a" && NSLocationInRange(paragraph.range.location, link.range)
                }
            }
            if topicLabel, ["div", "section", "aside"].contains(element.name),
               descendants.contains(where: { $0.name == "ul" || $0.name == "ol" }), !hasBodyParagraph {
                removed.append(element.range); reasons.append(.relatedContent); continue
            }
            let isInlineProse = elements.contains { ancestor in
                ancestor.name == "p" && ancestor.range != element.range &&
                    NSLocationInRange(element.range.location, ancestor.range) &&
                    ReaderHTMLSignals.plain(ns.substring(with: ancestor.range)) != text
            }
            let containsHeading = elements.contains { child in
                ["h1", "h2", "h3", "h4", "h5", "h6"].contains(child.name) &&
                    NSLocationInRange(child.range.location, element.range)
            }
            guard let reason = reason(tag: element.name, attributes: element.attributes, text: text,
                                      allowPhrase: !isInlineProse && !containsHeading) else { continue }
            removed.append(element.range)
            reasons.append(reason)
        }
        var result = html
        for range in removed.reversed() { result = (result as NSString).replacingCharacters(in: range, with: "") }
        return Result(html: result, reasons: reasons)
    }

    /// Whole linked card + a separate CTA leaf; never remove a prose paragraph
    /// merely because it contains the words "read more".
    private static func isRelatedCard(_ element: ReaderHTMLSignals.Element,
                                      descendants: [ReaderHTMLSignals.Element], source: NSString) -> Bool {
        guard ["a", "p", "div", "aside", "section"].contains(element.name) else { return false }
        let ctas = descendants.filter {
            ["span", "a", "button", "div"].contains($0.name) &&
                ReaderHTMLSignals.plain(source.substring(with: $0.range)).lowercased() == "read more"
        }
        let links = ([element] + descendants).filter { $0.name == "a" && $0.attributes["href"] != nil }
        guard !ctas.isEmpty, Set(links.compactMap { $0.attributes["href"] }).count == 1,
              links.contains(where: { link in
                  let title = ReaderHTMLSignals.plain(source.substring(with: link.range))
                  return title.count < 500 && title.lowercased() != "read more" && !title.isEmpty
              }) else { return false }
        let ranges = (links + ctas).map(\.range)
        let outer = Set(ranges).filter { range in
            !ranges.contains { $0 != range && NSLocationInRange(range.location, $0) }
        }
        var remainder = source.substring(with: element.range)
        for range in outer.sorted(by: { $0.location > $1.location }) {
            remainder = (remainder as NSString).replacingCharacters(in:
                NSRange(location: range.location - element.range.location, length: range.length), with: "")
        }
        return ReaderHTMLSignals.plain(remainder).isEmpty
    }

    static func standaloneReason(_ text: String) -> Reason? {
        switch text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "advertisement", "advertisement.", "sponsored content", "promoted content", "sponsor message": .semanticAdvertisement
        case "hide caption", "toggle caption", "view image in fullscreen": .socialTools
        case "sign up for our newsletter", "subscribe to our newsletter", "newsletter signup": .newsletterPromotion
        case "subscribe now", "support our journalism", "sign in", "register": .subscriptionPromotion
        case "share this article", "follow us": .socialTools
        case "download our app": .appPromotion
        case "accept all cookies", "manage cookie preferences": .privacyPrompt
        default: nil
        }
    }

    private static func reason(tag: String, attributes: [String: String], text: String, allowPhrase: Bool) -> Reason? {
        let role = attributes["role"]?.lowercased()
        if ["rich-link", "related-article", "related-content", "recommended-content"].contains(attributes["data-component"] ?? "") { return .relatedContent }
        if tag == "a", let href = attributes["href"] {
            if text == "Share", href.hasPrefix("mailto:") { return .socialTools }
            if text == "Reuse this content", href.hasPrefix("https://syndication.theguardian.com/") { return .socialTools }
            if text == "Prefer the Guardian on Google", href.hasPrefix("https://www.google.com/preferences/source") { return .subscriptionPromotion }
        }
        if tag == "nav" || role == "navigation" { return .navigation }
        if tag == "footer" || role == "contentinfo" { return .footer }
        let tokens = ReaderHTMLSignals.tokens(attributes)
        let rules: [(Set<String>, Reason)] = [
            (["advertisement", "ad-container", "ad-slot", "sponsored-content", "promoted-content"], .semanticAdvertisement),
            (["newsletter-signup", "newsletter-promotion", "newsletter-form"], .newsletterPromotion),
            (["contact-module", "contact-card", "author-contact", "author-contact-card", "get-in-touch", "contact-form"], .contactModule),
            (["subscription-prompt", "subscribe-prompt", "support-prompt", "login-prompt", "register-prompt"], .subscriptionPromotion),
            (["related-stories", "related-content", "recommended-stories", "most-viewed", "most-popular", "more-from"], .relatedContent),
            (["related-links", "related-internet-links", "recommended-content", "recommendations-module"], .relatedContent),
            (["related-card", "related-article", "inline-related", "element-rich-link", "element--rich-link"], .relatedContent),
            (["social-share", "share-tools", "share-buttons", "follow-us"], .socialTools),
            (["app-promotion", "download-app"], .appPromotion),
            (["cookie-banner", "cookie-consent", "privacy-prompt"], .privacyPrompt),
            (["site-navigation", "navigation-menu"], .navigation),
            (["site-footer", "page-footer"], .footer),
        ]
        if let rule = rules.first(where: { !$0.0.isDisjoint(with: tokens) }) { return rule.1 }
        // Whole UI phrases only, never keyword containment or article headings.
        let captionControl = ["b", "strong", "button"].contains(tag) && ["hide caption", "toggle caption"].contains(text.lowercased())
        return (allowPhrase || captionControl) && ["p", "div", "span", "a", "button", "b", "strong"].contains(tag) ? standaloneReason(text) : nil
    }
}

/// Small structural scanner shared by filtering and metadata classification.
/// It never repairs HTML or infers article content. The existing parser still
/// owns all rendering structure. Attribute values and URL targets stay verbatim.
enum ReaderHTMLSignals {
    struct Element {
        let name: String
        let attributes: [String: String]
        let range: NSRange
        let protected: Bool
    }
    private struct Open {
        let name: String
        let attributes: [String: String]
        let start: Int
        let protected: Bool
    }
    static let tags = try! NSRegularExpression(pattern: #"<!--[\s\S]*?-->|</?([A-Za-z][A-Za-z0-9:-]*)\b(?:[^>\"']|\"[^\"]*\"|'[^']*')*>"#)
    private static let attribute = try! NSRegularExpression(pattern: #"([A-Za-z_:][\w:.-]*)\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s>]+))"#)
    private static let voids: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"]

    static func elements(_ html: String) -> [Element] {
        let ns = html as NSString
        var stack: [Open] = []
        var result: [Element] = []
        for tag in tags.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            guard tag.range(at: 1).location != NSNotFound else { continue }
            let raw = ns.substring(with: tag.range)
            let name = ns.substring(with: tag.range(at: 1)).lowercased()
            if raw.hasPrefix("</") {
                guard let open = stack.last, open.name == name else { stack.removeAll(); continue }
                stack.removeLast()
                result.append(Element(name: name, attributes: open.attributes,
                    range: NSRange(location: open.start, length: NSMaxRange(tag.range) - open.start), protected: open.protected))
            } else if !voids.contains(name), !raw.hasSuffix("/>") {
                stack.append(Open(name: name, attributes: attributes(raw), start: tag.range.location,
                    protected: stack.last?.protected == true || ["blockquote", "pre", "code"].contains(name)))
            }
        }
        return result
    }

    static func attributes(_ openingTag: String) -> [String: String] {
        let ns = openingTag as NSString
        var result: [String: String] = [:]
        for match in attribute.matches(in: openingTag, range: NSRange(location: 0, length: ns.length)) {
            guard let value = (2...4).map({ match.range(at: $0) }).first(where: { $0.location != NSNotFound }) else { continue }
            result[ns.substring(with: match.range(at: 1)).lowercased()] = HTMLContentParser.decodeEntities(ns.substring(with: value))
        }
        return result
    }

    static func tokens(_ attributes: [String: String]) -> Set<String> {
        Set([attributes["class"], attributes["id"], attributes["itemprop"]].compactMap { $0 }
            .flatMap { $0.lowercased().split(whereSeparator: \.isWhitespace).map(String.init) })
    }

    static func plain(_ html: String) -> String {
        let ns = html as NSString
        var stripped = "", cursor = 0
        let boundaries: Set<String> = ["br", "p", "div", "section", "article", "aside", "li", "ul", "ol", "blockquote", "h1", "h2", "h3", "h4", "h5", "h6", "figcaption", "time"]
        for tag in tags.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            stripped += ns.substring(with: NSRange(location: cursor, length: tag.range.location - cursor))
            if tag.range(at: 1).location != NSNotFound, boundaries.contains(ns.substring(with: tag.range(at: 1)).lowercased()) {
                stripped += " "
            }
            cursor = NSMaxRange(tag.range)
        }
        stripped += ns.substring(from: cursor)
        return HTMLContentParser.decodeEntities(stripped)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
