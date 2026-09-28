import Foundation

public struct ArticleImageCandidate: Codable, Hashable, Sendable {
    public enum Source: String, Codable, Sendable {
        case rssMedia, rssThumbnail, openGraph, twitterImage, articleLeadImage, articleImage, srcset, existing
    }
    public var url: URL
    public var source: Source
    public var width: Int?
    public var height: Int?
    /// Structural evidence, never inferred solely from a filename.
    public var decorative: Bool

    public init(url: URL, source: Source, width: Int? = nil, height: Int? = nil, decorative: Bool = false) {
        self.url = url; self.source = source; self.width = width; self.height = height; self.decorative = decorative
    }
}

public enum ArticleImageQuality: String, Codable, Sendable { case high, medium, low, unknown }
public enum ArticleImageUse: Sendable { case hero, card }

/// All resolution thresholds and source/geometry tradeoffs live here, not in views.
public enum ArticleImagePolicy {
    public static let heroWidth = 1_000
    public static let cardWidth = 500

    public static func quality(_ candidate: ArticleImageCandidate) -> ArticleImageQuality {
        guard let width = candidate.width, width > 0 else { return .unknown }
        if width >= heroWidth { return .high }
        if width >= cardWidth { return .medium }
        return .low
    }

    public static func acceptable(_ image: ArticleImageCandidate) -> Bool {
        guard ["http", "https"].contains(image.url.scheme?.lowercased() ?? ""),
              image.url.host != nil, !image.decorative else { return false }
        if let w = image.width, w > 0, w < 80 { return false }
        if let h = image.height, h > 0, h < 60 { return false }
        // A name is only supporting evidence; a large news photograph named
        // "company-logo-protest.jpg" remains eligible.
        let tokens = Set(image.url.deletingPathExtension().lastPathComponent.lowercased()
            .split(whereSeparator: { !$0.isLetter }).map(String.init))
        let suspect = !tokens.isDisjoint(with: ["logo", "icon", "avatar", "favicon", "sprite", "tracking", "pixel", "spacer"])
        if suspect, let w = image.width, let h = image.height, w <= 300, h <= 300 { return false }
        return true
    }

    public static func permits(_ image: ArticleImageCandidate, use: ArticleImageUse) -> Bool {
        guard acceptable(image) else { return false }
        if case .hero = use {
            guard quality(image) == .high else { return false }
            if let w = image.width, let h = image.height, h > 0 {
                return (0.8...3.0).contains(Double(w) / Double(h))
            }
        }
        return true // Small cards may still use the only available thumbnail.
    }

    static func score(_ image: ArticleImageCandidate) -> Double {
        let resolution: Double
        switch quality(image) {
        case .high: resolution = 600
        case .medium: resolution = 350
        case .low: resolution = 50
        case .unknown: resolution = 180
        }
        let trust: Double
        switch image.source {
        case .openGraph: trust = 100
        case .rssMedia: trust = 110
        case .articleLeadImage: trust = 90
        case .srcset: trust = 80
        case .twitterImage: trust = 70
        case .articleImage: trust = 30
        case .rssThumbnail: trust = 10
        case .existing: trust = 40
        }
        var geometry = 0.0
        if let w = image.width, let h = image.height, w > 0, h > 0 {
            let ratio = Double(w) / Double(h)
            geometry = (1.2...2.0).contains(ratio) ? 60 : ((0.65...3.0).contains(ratio) ? 0 : -600)
        }
        return resolution + trust + geometry + Double(min(max(image.width ?? 0, 0), 2400)) / 100
    }

    public static func ranked(_ candidates: [ArticleImageCandidate]) -> [ArticleImageCandidate] {
        var best: [URL: ArticleImageCandidate] = [:]
        for candidate in candidates where acceptable(candidate) {
            if let old = best[candidate.url], score(old) >= score(candidate) { continue }
            best[candidate.url] = candidate
        }
        return best.values.sorted {
            let a = score($0), b = score($1)
            return a == b ? $0.url.absoluteString < $1.url.absoluteString : a > b
        }
    }

    public static func rssCandidates(_ article: Article) -> [ArticleImageCandidate] {
        var values = article.rssImages.map {
            ArticleImageCandidate(url: $0.url, source: $0.provenance == .mediaThumbnail ? .rssThumbnail : .rssMedia,
                                  width: $0.width, height: $0.height)
        }
        if let url = article.heroImageURL, !values.contains(where: { $0.url == url }) {
            values.append(.init(url: url, source: .existing))
        }
        return values
    }
}

/// Image metadata inspection only; the existing Reader parsers retain ownership
/// of extraction. Raw page images must belong to article/main/figure, never the
/// first arbitrary img in a page. Extracted fragments are already article scoped.
enum ArticleImageHTML {
    static func candidates(_ html: String, baseURL: URL, extracted: Bool = false) -> [ArticleImageCandidate] {
        let ns = html as NSString
        let elements = ReaderHTMLSignals.elements(html)
        var values: [ArticleImageCandidate] = []
        var ogIndices: [Int] = []
        var bodyImages = 0
        func url(_ raw: String?) -> URL? {
            guard let raw, !raw.isEmpty, let value = URL(string: raw, relativeTo: baseURL)?.absoluteURL,
                  ["http", "https"].contains(value.scheme?.lowercased() ?? ""), value.host != nil else { return nil }
            return value
        }
        func dimension(_ raw: String?) -> Int? { raw.flatMap(Int.init).flatMap { (1...100_000).contains($0) ? $0 : nil } }
        for tag in ReaderHTMLSignals.tags.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            guard tag.range(at: 1).location != NSNotFound else { continue }
            let raw = ns.substring(with: tag.range)
            guard !raw.hasPrefix("</") else { continue }
            let name = ns.substring(with: tag.range(at: 1)).lowercased()
            let a = ReaderHTMLSignals.attributes(raw)
            if name == "meta" {
                let key = (a["property"] ?? a["name"] ?? "").lowercased()
                if ["og:image", "og:image:url", "og:image:secure_url", "twitter:image", "twitter:image:src"].contains(key), let value = url(a["content"]) {
                    if key == "og:image" || key == "og:image:url" { ogIndices = [] }
                    let previous = key == "og:image:secure_url" ? ogIndices.last.map { values[$0] } : nil
                    values.append(.init(url: value, source: key.hasPrefix("og:") ? .openGraph : .twitterImage,
                                        width: previous?.width, height: previous?.height))
                    if key.hasPrefix("og:") { ogIndices.append(values.count - 1) }
                } else if key == "og:image:width" || key == "og:image:height" {
                    for index in ogIndices {
                        if key.hasSuffix("width") { values[index].width = dimension(a["content"]) }
                        else { values[index].height = dimension(a["content"]) }
                    }
                }
                continue
            }
            guard name == "img" || name == "source" else { continue }
            let ancestors = elements.filter { NSLocationInRange(tag.range.location, $0.range) }
            guard extracted || ancestors.contains(where: { ["article", "main", "figure"].contains($0.name) }) else { continue }
            let tokens = ancestors.reduce(ReaderHTMLSignals.tokens(a)) { $0.union(ReaderHTMLSignals.tokens($1.attributes)) }
            let decorative = !tokens.isDisjoint(with: ["avatar", "author-avatar", "author-portrait", "logo", "site-logo", "social-icon", "tracking-pixel"])
                || ancestors.contains { ["nav", "footer", "aside", "script", "style"].contains($0.name) }
            let w = dimension(a["width"]), h = dimension(a["height"])
            if let value = url(a["src"]) {
                values.append(.init(url: value, source: bodyImages == 0 ? .articleLeadImage : .articleImage,
                                    width: w, height: h, decorative: decorative))
                if !decorative { bodyImages += 1 }
            }
            // Only explicit width/density descriptors; never manufacture CDN URLs.
            for entry in (a["srcset"] ?? "").split(separator: ",") {
                let parts = entry.split(whereSeparator: \.isWhitespace).map(String.init)
                guard parts.count == 2, let value = url(parts.first), let descriptor = parts.last,
                      let amount = Double(descriptor.dropLast()), amount.isFinite, amount > 0, amount <= 20_000 else { continue }
                let width: Int?
                if descriptor.hasSuffix("w") { width = Int(amount) }
                else if descriptor.hasSuffix("x"), amount > 1, amount <= 8 { width = w.map { Int(Double($0) * amount) } }
                else { width = nil }
                guard width.map({ $0 > (w ?? 0) }) ?? (descriptor.hasSuffix("x") && amount > 1 && amount <= 8) else { continue }
                let height = width.flatMap { target in w.flatMap { original in h.map { Int(Double($0) * Double(target) / Double(original)) } } }
                values.append(.init(url: value, source: .srcset, width: width, height: height, decorative: decorative))
            }
        }
        return ArticleImagePolicy.ranked(values)
    }
}
