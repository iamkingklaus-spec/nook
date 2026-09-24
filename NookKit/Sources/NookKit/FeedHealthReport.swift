import Foundation

/// A local observation, not a durable property of a subscription. Never added to
/// Feed, Article, refresh timestamps, SQLite replicas or sync shards.
public struct FeedHealthReport: Equatable, Sendable {
    public enum Format: String, Sendable { case rss = "RSS", atom = "Atom", unknown }
    public enum ParseResult: String, Sendable { case notTested, success, malformedXML, notFeed, webPage }
    public enum Severity: Sendable { case normal, warning, failure, untested }

    public let requestedURL: URL
    public var finalURL: URL?
    public var httpStatus: Int?
    public var format: Format = .unknown
    public var parseResult: ParseResult = .notTested
    public var itemCount = 0
    public var articleLinks: [FeedArticleLinkCheck] = []
    public var extractionSamples: [FeedExtractionSample]?
    public var extractionCheckedAt: Date?
    public let checkedAt: Date
    public var errorReason: String?
    /// Advertised HTML links only. Discovery is reported, never followed.
    public var discoveredFeedURLs: [URL] = []

    public var validArticleURLCount: Int { articleLinks.filter { $0.status == .valid }.count }
    public var missingArticleURLCount: Int { articleLinks.filter { $0.status == .missing }.count }
    public var invalidArticleURLCount: Int { articleLinks.filter { $0.status == .invalid }.count }
    public var homepageFallbackCount: Int { articleLinks.filter { $0.status == .homepageFallback }.count }
    public var invalidOrMissingArticleURLCount: Int { articleLinks.count - validArticleURLCount }
    public var canSample: Bool { parseResult == .success && validArticleURLCount > 0 }

    public var severity: Severity {
        guard parseResult == .success else {
            return parseResult == .notTested && errorReason == nil ? .untested : .failure
        }
        if invalidOrMissingArticleURLCount > 0 || extractionSamples?.contains(where: { $0.quality != .fullCandidate }) == true {
            return .warning
        }
        return .normal
    }

    public var feedDescription: String {
        switch parseResult {
        case .success: itemCount == 0 ? "Feed 正常，目前没有文章。" : "Feed: Normal · RSS / Atom 正常"
        case .malformedXML: "RSS / Atom 解析失败"
        case .webPage: "当前 URL 是网页，不是 Feed"
        case .notFeed: "XML 可解析，但不是支持的 RSS / Atom Feed"
        case .notTested: errorReason == nil ? "Feed 尚未检测" : "Feed 网络请求失败"
        }
    }

    public var extractionDescription: String {
        guard let samples = extractionSamples else { return "正文未测试" }
        guard !samples.isEmpty else { return "没有可抽样的有效文章链接" }
        if samples.allSatisfy({ $0.quality == .fullCandidate }) { return "正文抽样正常 · Full content candidate" }
        if samples.contains(where: { $0.quality == .unavailable }) { return "部分正文抽样失败，仅代表已抽样文章" }
        return "正文抽样可能只有摘要"
    }

    public init(requestedURL: URL, checkedAt: Date = .now) {
        self.requestedURL = requestedURL
        self.checkedAt = checkedAt
    }
}

public struct FeedArticleLinkCheck: Equatable, Sendable {
    public enum Status: String, Sendable { case valid, missing, invalid, homepageFallback }
    public let rawValue: String?
    public let url: URL?
    public let status: Status

    static func isWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host(percentEncoded: false), !host.isEmpty,
              host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              url.absoluteString.components(separatedBy: "://").count == 2,
              url.user == nil, url.password == nil else { return false }
        return url.port.map { (1...65535).contains($0) } ?? true
    }

    static func inspect(_ raw: String?, baseURL: URL, siteURL: URL) -> Self {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return .init(rawValue: raw, url: nil, status: .missing)
        }
        // Do not repair bad schemes or auto-encode whitespace into an apparently
        // healthy link. Resolve legitimate relative references against xml:base.
        guard value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              !value.contains("\\"),
              value.range(of: "%(?![0-9a-fA-F]{2})", options: .regularExpression) == nil,
              !value.hasPrefix("#"),
              let url = URL(string: value, relativeTo: baseURL)?.absoluteURL,
              Self.isWebURL(url) else {
            return .init(rawValue: raw, url: nil, status: .invalid)
        }
        func canonical(_ url: URL) -> String {
            var c = URLComponents(url: url, resolvingAgainstBaseURL: true)
            c?.fragment = nil
            c?.scheme = c?.scheme?.lowercased()
            c?.host = c?.host?.lowercased()
            if var path = c?.path {
                while path.hasSuffix("/") { path.removeLast() }
                c?.path = path
            }
            return c?.string ?? url.absoluteString
        }
        let homepage = canonical(url) == canonical(siteURL) ||
            ((url.path.isEmpty || url.path == "/") && url.query == nil)
        return .init(rawValue: raw, url: url, status: homepage ? .homepageFallback : .valid)
    }
}

public struct FeedExtractionSample: Equatable, Sendable {
    public let articleURL: URL
    public let quality: ReaderContentQuality
    public let checkedAt: Date
    public let errorReason: String?

    public init(articleURL: URL, quality: ReaderContentQuality, checkedAt: Date = .now, errorReason: String? = nil) {
        self.articleURL = articleURL
        self.quality = quality
        self.checkedAt = checkedAt
        self.errorReason = errorReason
    }
}

/// Bodies are retained only in the short-lived, bounded in-memory diagnostic cache.
struct FeedHealthSnapshot: Sendable {
    var report: FeedHealthReport
    var articles: [Article] = []
}
