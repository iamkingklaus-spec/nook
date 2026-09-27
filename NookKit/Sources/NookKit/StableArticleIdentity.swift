import Foundation

/// Device-local association and presentation identity, independent of feed IDs.
/// Keep meaningful query parameters and path casing; never deduplicate by title.
public enum StableArticleIdentity {
    public static func canonicalURL(_ url: URL) -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return url }
        parts.fragment = nil
        parts.scheme = parts.scheme?.lowercased()
        parts.host = parts.host?.lowercased()
        if (parts.scheme == "https" && parts.port == 443) || (parts.scheme == "http" && parts.port == 80) { parts.port = nil }
        if parts.path.isEmpty { parts.path = "/" }
        return parts.url ?? url
    }

    public static func key(_ article: Article) -> String {
        let url = canonicalURL(article.url)
        guard ["http", "https"].contains(url.scheme ?? ""), url.host != nil else { return "id:" + article.id }
        return "url:" + url.absoluteString
    }
}
