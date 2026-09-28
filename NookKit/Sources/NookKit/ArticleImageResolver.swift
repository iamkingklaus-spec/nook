import Foundation

public struct ArticleImageResolution: Codable, Sendable {
    public let preferred: ArticleImageCandidate?
    public let resolvedAt: Date
    public var quality: ArticleImageQuality { preferred.map(ArticleImagePolicy.quality) ?? .unknown }
    public func image(for use: ArticleImageUse) -> ArticleImageCandidate? {
        preferred.flatMap { ArticleImagePolicy.permits($0, use: use) ? $0 : nil }
    }
}

/// Device-local enrichment; no Article/user-state mutation, hence no Home edition
/// reorder or cross-device claims about a temporarily unavailable image.
public actor ArticleImageResolver {
    public static let shared = ArticleImageResolver()
    private struct Record: Codable {
        let fingerprint: String
        let resolution: ArticleImageResolution
    }
    private let pages: ArticleImagePageStore
    private let images: ArticleImageCache
    private let directory: URL?
    private var records: [String: Record] = [:]
    private var pending: [String: Task<ArticleImageResolution, Never>] = [:]

    init(pages: ArticleImagePageStore = .shared, images: ArticleImageCache = .shared,
         directory: URL? = ArticleImageFiles.directory("resolved")) {
        self.pages = pages; self.images = images; self.directory = directory
    }

    /// Called by a visible card only. RSS and already extracted article markup
    /// are cheap local candidates; full page metadata is reused when available.
    public func resolve(_ article: Article) async -> ArticleImageResolution {
        let id = StableArticleIdentity.key(article)
        let rss = ArticleImagePolicy.rssCandidates(article)
        let page = await pages.cached(article.url)
        let fingerprint = self.fingerprint(article, rss: rss, page: page)
        if let record = records[id], valid(record, fingerprint: fingerprint) { return record.resolution }
        if let file = ArticleImageFiles.file(id, in: directory), let data = try? Data(contentsOf: file),
           let record = try? JSONDecoder().decode(Record.self, from: data), valid(record, fingerprint: fingerprint) {
            records[id] = record; return record.resolution
        }
        let requestKey = id + fingerprint
        if let task = pending[requestKey] { return await task.value }
        let task = Task { [pages, images] in
            var candidates = rss
            let hasDownloadedHTML = article.contentSource == .extractedReaderContent && article.contentHTML != nil
            if let html = article.contentHTML {
                candidates += ArticleImageHTML.candidates(html, baseURL: article.url, extracted: true)
            }
            let best = ArticleImagePolicy.ranked(candidates).first
            // No page request for a good RSS image; no second page request when
            // Reader already supplied HTML. Network enrichment stays lazy.
            let needsPage = best.map { !ArticleImagePolicy.permits($0, use: .hero) } ?? true
            let snapshot = await pages.page(article.url, allowNetwork: needsPage && !hasDownloadedHTML)
            candidates += snapshot?.candidates ?? []
            var measured: [ArticleImageCandidate] = []
            var attempted: Set<URL> = []
            // Bounded probes; invalid OG and failed URLs fall through to RSS.
            for var candidate in ArticleImagePolicy.ranked(candidates).prefix(6) {
                guard !Task.isCancelled else { break }
                attempted.insert(candidate.url)
                guard let data = try? await images.data(for: candidate.url),
                      let (width, height) = ArticleImageCache.dimensions(data) else { continue }
                candidate.width = width; candidate.height = height
                if ArticleImagePolicy.acceptable(candidate) { measured.append(candidate) }
                // Once a verified high-quality landscape is found, lower-ranked
                // known thumbnails add cost without improving the presentation.
                if ArticleImagePolicy.permits(candidate, use: .hero) { break }
            }
            // RSS dimensions can be optimistic or the URL can fail. Verify them
            // before deciding a high-quality RSS candidate makes enrichment moot.
            if !needsPage, snapshot == nil, !hasDownloadedHTML,
               !measured.contains(where: { ArticleImagePolicy.permits($0, use: .hero) }),
               let fallback = await pages.page(article.url, allowNetwork: true) {
                for var candidate in ArticleImagePolicy.ranked(fallback.candidates).filter({ !attempted.contains($0.url) }).prefix(3) {
                    guard let data = try? await images.data(for: candidate.url),
                          let (w, h) = ArticleImageCache.dimensions(data) else { continue }
                    candidate.width = w; candidate.height = h
                    if ArticleImagePolicy.acceptable(candidate) { measured.append(candidate) }
                    if ArticleImagePolicy.permits(candidate, use: .hero) { break }
                }
            }
            return ArticleImageResolution(preferred: ArticleImagePolicy.ranked(measured).first, resolvedAt: .now)
        }
        pending[requestKey] = task
        let result = await task.value
        pending[requestKey] = nil
        // Include the newly cached page in the saved fingerprint too.
        let latest = await pages.cached(article.url)
        let finalFingerprint = self.fingerprint(article, rss: rss, page: latest)
        let record = Record(fingerprint: finalFingerprint, resolution: result)
        if records.count >= 300 { records.removeAll() }
        records[id] = record
        if let data = try? JSONEncoder().encode(record) { ArticleImageFiles.write(data, key: id, directory: directory) }
        return result
    }

    private func fingerprint(_ article: Article, rss: [ArticleImageCandidate], page: ArticleImagePageStore.Snapshot?) -> String {
        ArticleDocument.digest(["image-policy-v1", article.url.absoluteString, article.contentHTML ?? "",
            page?.checkedAt.description ?? ""] + rss.flatMap {
                [$0.url.absoluteString, $0.source.rawValue, String($0.width ?? 0), String($0.height ?? 0)]
            })
    }

    private func valid(_ record: Record, fingerprint: String) -> Bool {
        record.fingerprint == fingerprint && Date.now.timeIntervalSince(record.resolution.resolvedAt)
            < (record.resolution.preferred == nil ? 300 : (record.resolution.quality == .high ? 86_400 : 900))
    }
}
