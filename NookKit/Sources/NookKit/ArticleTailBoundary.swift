import Foundation

/// A conservative post-extraction pass. Semantic containers are removed by
/// ArticleNoiseFilter before their provenance is flattened. This pass handles
/// the remaining terminal modules in sanitized extractor output.
enum ArticleTailBoundary {
    struct Result { let blocks: [HTMLContentBlock]; let reasons: [ArticleNoiseFilter.Reason] }

    static func marker(_ text: String) -> ArticleNoiseFilter.Reason? {
        switch text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "get in touch", "contact us", "contact form": return .contactModule
        case "follow us", "share", "share this article": return .socialTools
        case "related internet links", "related links", "explore more on these topics", "related topics",
             "related stories", "more on this story", "recommended", "most viewed", "most popular", "read more": return .relatedContent
        case "sign up", "subscribe", "support us": return .subscriptionPromotion
        default:
            let value = text.lowercased()
            return value.hasPrefix("more from ") && value.count < 80 ? .relatedContent : nil
        }
    }

    static func clean(_ blocks: [HTMLContentBlock], sourceURL: URL?) -> Result {
        let host = sourceURL?.host?.lowercased() ?? ""
        let bbc = host == "bbc.com" || host.hasSuffix(".bbc.com") || host == "bbc.co.uk" || host.hasSuffix(".bbc.co.uk")
        let guardian = host == "theguardian.com" || host.hasSuffix(".theguardian.com")
        var retained: [HTMLContentBlock] = [], reasons: [ArticleNoiseFilter.Reason] = []
        var metadataSeen = Set<String>()
        for block in blocks {
            if let html = textHTML(block), case .text = block {
                let text = ReaderHTMLSignals.plain(html)
                let eligibility = TranslationEligibility.classify(html)
                if [.author, .authorRole, .publisher, .publicationDate, .photoCredit].contains(eligibility),
                   !metadataSeen.insert(eligibility.rawValue + ":" + text).inserted {
                    reasons.append(.duplicate); continue
                }
            }
            retained.append(block)
        }
        // A marker alone never truncates the article. Every following block must
        // match the module grammar, and earlier prose must exist. Quotes/code/
        // tables/images and unrecognized prose veto the cut.
        for index in retained.indices where index > 0 && index + 1 < retained.count {
            guard let html = textHTML(retained[index]), let reason = marker(ReaderHTMLSignals.plain(html)),
                  retained[..<index].contains(where: isBody),
                  retained[(index + 1)...].allSatisfy({ moduleBlock($0, bbc: bbc, guardian: guardian) }),
                  retained[(index + 1)...].contains(where: {
                      hasModuleEvidence($0) || textHTML($0).flatMap { publisherModule($0, bbc: bbc, guardian: guardian) } != nil
                  }) else { continue }
            reasons.append(reason)
            reasons.append(.tailBoundary)
            retained = Array(retained[..<index])
            break
        }
        // Do this after boundary detection: deleting a contact form first would
        // discard the evidence and leave its now-orphaned "Get in touch" heading.
        let cleaned = retained.filter { block in
            guard case .text(let html) = block, let reason = publisherModule(html, bbc: bbc, guardian: guardian) else { return true }
            reasons.append(reason)
            return false
        }
        return Result(blocks: cleaned, reasons: reasons)
    }

    private static func textHTML(_ block: HTMLContentBlock) -> String? {
        switch block { case .text(let html), .heading(_, let html): return html; default: return nil }
    }
    private static func isBody(_ block: HTMLContentBlock) -> Bool {
        guard case .text(let html) = block else { return false }
        return TranslationEligibility.classify(html) == .prose && marker(ReaderHTMLSignals.plain(html)) == nil && !linksOnly(html)
    }
    private static func hasModuleEvidence(_ block: HTMLContentBlock) -> Bool {
        switch block {
        case .text(let html): return linksOnly(html)
        case .list(_, let items): return !items.isEmpty && items.allSatisfy { !$0.isEmpty && $0.allSatisfy(hasModuleEvidence) }
        default: return false
        }
    }
    private static func moduleBlock(_ block: HTMLContentBlock, bbc: Bool, guardian: Bool) -> Bool {
        switch block {
        case .text(let html), .heading(_, let html):
            if marker(ReaderHTMLSignals.plain(html)) != nil || publisherModule(html, bbc: bbc, guardian: guardian, withinTail: true) != nil { return true }
            let kind = TranslationEligibility.classify(html)
            return linksOnly(html) || [.publicationDate, .author, .authorRole, .publisher, .photoCredit, .empty].contains(kind)
        case .list: return hasModuleEvidence(block)
        default: return false
        }
    }

    private static func publisherModule(_ html: String, bbc: Bool, guardian: Bool, withinTail: Bool = false) -> ArticleNoiseFilter.Reason? {
        let text = ReaderHTMLSignals.plain(html)
        guard text.count < 700 else { return nil }
        let links = ReaderHTMLSignals.elements(html).filter { $0.name == "a" }
        if bbc {
            if text.hasPrefix("Tell us which stories we should cover"), withinTail || !links.isEmpty { return .contactModule }
            if text.hasPrefix("Follow BBC "), !links.isEmpty,
               text.contains(" on "), ["BBC Sounds", "Facebook", "Instagram"].contains(where: text.contains) { return .socialTools }
        }
        if guardian, text.lowercased().hasPrefix("prefer "), text.contains("Google"),
           links.contains(where: { URL(string: $0.attributes["href"] ?? "")?.host == "www.google.com" }) { return .subscriptionPromotion }
        return nil
    }

    private static func linksOnly(_ html: String) -> Bool {
        let links = ReaderHTMLSignals.elements(html).filter { $0.name == "a" }
        guard !links.isEmpty else { return false }
        var remainder = html
        let outer = links.filter { link in
            !links.contains { $0.range != link.range && NSLocationInRange(link.range.location, $0.range) }
        }
        for link in outer.sorted(by: { $0.range.location > $1.range.location }) {
            remainder = (remainder as NSString).replacingCharacters(in: link.range, with: "")
        }
        let plain = ReaderHTMLSignals.plain(remainder)
        return plain.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).contains($0) }
    }
}
