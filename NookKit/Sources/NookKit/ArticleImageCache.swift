import Foundation
import ImageIO

/// Shared image/page network budget caps active transfers at two.
actor ArticleImageNetwork {
    static let shared = ArticleImageNetwork()
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func fetch(_ url: URL, limit: Int) async throws -> Data {
        if active >= 2 { await withCheckedContinuation { waiters.append($0) } }
        else { active += 1 }
        defer {
            if waiters.isEmpty { active -= 1 } else { waiters.removeFirst().resume() }
        }
        try Task.checkCancellation()
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (file, response) = try await URLSession.shared.download(for: request)
        defer { try? FileManager.default.removeItem(at: file) }
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
              let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= limit else {
            throw URLError(.badServerResponse)
        }
        return try Data(contentsOf: file)
    }
}

enum ArticleImageFiles {
    static func directory(_ name: String) -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Nook/ArticleImages/v1/" + name, isDirectory: true)
    }
    static func file(_ key: String, in directory: URL?) -> URL? {
        directory?.appendingPathComponent(ArticleDocument.digest([key]) + ".cache")
    }
    static func write(_ data: Data, key: String, directory: URL?, maxBytes: Int = 32_000_000) {
        guard let directory, let file = file(key, in: directory) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            let files = try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
            let sorted = files.filter { $0.pathExtension == "cache" }.sorted {
                ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            }
            var total = 0
            for (index, item) in sorted.enumerated() {
                total += (try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if index >= 500 || total > maxBytes { try? FileManager.default.removeItem(at: item) }
            }
        } catch { /* Optional cache; never block article loading. */ }
    }
}

public actor ArticleImageCache {
    public static let shared = ArticleImageCache()
    typealias Fetch = @Sendable (URL) async throws -> Data
    private let directory: URL?
    private let fetch: Fetch
    private var memory: [URL: Data] = [:]
    private var pending: [URL: Task<Data, Error>] = [:]

    init(directory: URL? = ArticleImageFiles.directory("images"), fetch: @escaping Fetch = {
        try await ArticleImageNetwork.shared.fetch($0, limit: 20_000_000)
    }) { self.directory = directory; self.fetch = fetch }

    public func data(for url: URL) async throws -> Data {
        if let data = memory[url] { return data }
        if let task = pending[url] { return try await task.value }
        if let file = ArticleImageFiles.file(url.absoluteString, in: directory),
           let data = try? Data(contentsOf: file), Self.dimensions(data) != nil {
            remember(data, url: url); return data
        }
        let task = Task { [fetch] in
            let data = try await fetch(url)
            guard Self.dimensions(data) != nil,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 64
                  ] as CFDictionary) != nil else { throw URLError(.cannotDecodeContentData) }
            return data
        }
        pending[url] = task
        defer { pending[url] = nil }
        let data = try await task.value
        remember(data, url: url)
        ArticleImageFiles.write(data, key: url.absoluteString, directory: directory, maxBytes: 150_000_000)
        return data
    }

    private func remember(_ data: Data, url: URL) {
        if memory.values.reduce(0, { $0 + $1.count }) + data.count > 32_000_000 { memory.removeAll() }
        memory[url] = data
    }

    static func dimensions(_ data: Data) -> (Int, Int)? {
        guard data.count <= 20_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0,
              Double(w) * Double(h) <= 80_000_000 else { return nil }
        return (w, h)
    }
}

/// Retains candidates derived from HTML already downloaded by Reader. A Reader
/// extraction in flight is awaited instead of issuing a second page request.
actor ArticleImagePageStore {
    static let shared = ArticleImagePageStore()
    struct Snapshot: Codable, Sendable {
        var candidates: [ArticleImageCandidate]
        var checkedAt: Date
    }
    private let directory: URL?
    private let fetch: ArticleImageCache.Fetch
    private var memory: [String: Snapshot] = [:]
    private var pending: [String: Task<Snapshot?, Never>] = [:]
    private var extracting: [String: Int] = [:]
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    init(directory: URL? = ArticleImageFiles.directory("pages"), fetch: @escaping ArticleImageCache.Fetch = {
        try await ArticleImageNetwork.shared.fetch($0, limit: 4_000_000)
    }) { self.directory = directory; self.fetch = fetch }

    func beginExtraction(_ url: URL) { extracting[key(url), default: 0] += 1 }
    func endExtraction(_ url: URL, html: String?) {
        let id = key(url)
        if let html { ingest(html, url: url) }
        extracting[id, default: 1] -= 1
        if extracting[id, default: 0] <= 0 {
            extracting[id] = nil
            waiters.removeValue(forKey: id)?.forEach { $0.resume() }
        }
    }
    func ingest(_ html: String, url: URL) {
        let snapshot = Snapshot(candidates: ArticleImageHTML.candidates(html, baseURL: url), checkedAt: .now)
        save(snapshot, id: key(url))
    }
    func cached(_ url: URL) -> Snapshot? {
        let id = key(url)
        if let value = memory[id], Date.now.timeIntervalSince(value.checkedAt) < 86_400 { return value }
        if let file = ArticleImageFiles.file(id, in: directory), let data = try? Data(contentsOf: file),
           let value = try? JSONDecoder().decode(Snapshot.self, from: data),
           Date.now.timeIntervalSince(value.checkedAt) < 86_400 { memory[id] = value; return value }
        return nil
    }
    func page(_ url: URL, allowNetwork: Bool) async -> Snapshot? {
        let id = key(url)
        if extracting[id] != nil {
            await withCheckedContinuation { waiters[id, default: []].append($0) }
            // Even a failed Reader load doesn't trigger an image-only duplicate.
            return cached(url)
        }
        if let value = cached(url) { return value }
        guard allowNetwork, !Task.isCancelled else { return nil }
        if let task = pending[id] { return await task.value }
        let task = Task { [fetch] () -> Snapshot? in
            guard let data = try? await fetch(url), let html = String(data: data, encoding: .utf8) else { return nil }
            return Snapshot(candidates: ArticleImageHTML.candidates(html, baseURL: url), checkedAt: .now)
        }
        pending[id] = task
        let value = await task.value
        pending[id] = nil
        // A fresh Reader snapshot wins over a concurrently completed image request.
        if let existing = cached(url) { return existing }
        if let value { save(value, id: id) }
        return value
    }
    private func key(_ url: URL) -> String { StableArticleIdentity.canonicalURL(url).absoluteString }
    private func save(_ snapshot: Snapshot, id: String) {
        if memory.count >= 100 { memory.removeAll() }
        memory[id] = snapshot
        if let data = try? JSONEncoder().encode(snapshot) { ArticleImageFiles.write(data, key: id, directory: directory) }
    }
}
