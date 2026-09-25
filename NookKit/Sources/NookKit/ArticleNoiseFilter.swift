import Foundation

/// A conservative pass over already-extracted HTML, not another article parser.
/// Only explicitly closed containers are considered; uncertain markup survives.
enum ArticleNoiseFilter {
    enum Reason: String, Sendable {
        case semanticAdvertisement, navigation, newsletterPromotion, subscriptionPromotion
        case relatedContent, socialTools, appPromotion, privacyPrompt, footer
        case empty, duplicate, duplicateCaption
    }
    struct Result: Sendable {
        let html: String
        let reasons: [Reason]
    }

    static func filter(_ html: String) -> Result {
        let elements = ReaderHTMLSignals.elements(html)
        let ns = html as NSString
        var removed: [NSRange] = []
        var reasons: [Reason] = []
        for element in elements.sorted(by: { $0.range.location < $1.range.location }) {
            guard !removed.contains(where: { NSLocationInRange(element.range.location, $0) }),
                  !element.protected,
                  !elements.contains(where: { ["blockquote", "pre", "code"].contains($0.name) && NSLocationInRange($0.range.location, element.range) }) else { continue }
            let text = ReaderHTMLSignals.plain(ns.substring(with: element.range))
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

    static func standaloneReason(_ text: String) -> Reason? {
        switch text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "advertisement", "advertisement.", "sponsored content", "promoted content": .semanticAdvertisement
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
        if tag == "nav" || role == "navigation" { return .navigation }
        if role == "contentinfo" { return .footer }
        let tokens = ReaderHTMLSignals.tokens(attributes)
        let rules: [(Set<String>, Reason)] = [
            (["advertisement", "ad-container", "ad-slot", "sponsored-content", "promoted-content"], .semanticAdvertisement),
            (["newsletter-signup", "newsletter-promotion", "newsletter-form"], .newsletterPromotion),
            (["subscription-prompt", "subscribe-prompt", "support-prompt", "login-prompt", "register-prompt"], .subscriptionPromotion),
            (["related-stories", "related-content", "recommended-stories", "most-viewed", "most-popular", "more-from"], .relatedContent),
            (["social-share", "share-tools", "share-buttons", "follow-us"], .socialTools),
            (["app-promotion", "download-app"], .appPromotion),
            (["cookie-banner", "cookie-consent", "privacy-prompt"], .privacyPrompt),
            (["site-navigation", "navigation-menu"], .navigation),
            (["site-footer", "page-footer"], .footer),
        ]
        if let rule = rules.first(where: { !$0.0.isDisjoint(with: tokens) }) { return rule.1 }
        // Whole UI phrases only, never keyword containment or article headings.
        return allowPhrase && ["p", "div", "span", "a", "button"].contains(tag) ? standaloneReason(text) : nil
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
        let stripped = tags.stringByReplacingMatches(in: html,
            range: NSRange(location: 0, length: (html as NSString).length), withTemplate: " ")
        return HTMLContentParser.decodeEntities(stripped)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
