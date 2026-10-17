import Foundation

// This Foundation-only file is also compiled into the share targets. Neither
// the parser, ReaderStore nor any Gemini/credential code is linked into them.
public enum SharedArticleError: LocalizedError {
    case invalidURL, unavailableContainer, invalidEnvelope, importInProgress
    public var errorDescription: String? {
        switch self {
        case .invalidURL: "请提供有效的 http / https 文章链接。"
        case .unavailableContainer: "当前签名没有共享空间。请复制链接，再到 Nookie 中粘贴并打开。"
        case .invalidEnvelope: "无法读取这条分享记录；原文件已保留。"
        case .importInProgress: "分享队列正在导入，请稍后重试。"
        }
    }
}

public enum SharedArticleURL {
    public static func validate(_ text: String) throws -> URL {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, raw.utf8.count <= 16_384, !raw.contains(where: \.isWhitespace),
              var parts = URLComponents(string: raw),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true else { throw SharedArticleError.invalidURL }
        parts.scheme = parts.scheme?.lowercased(); parts.host = host.lowercased(); parts.fragment = nil
        if (parts.scheme == "https" && parts.port == 443) || (parts.scheme == "http" && parts.port == 80) { parts.port = nil }
        if parts.path.isEmpty { parts.path = "/" }
        guard let result = parts.url else { throw SharedArticleError.invalidURL }
        return result
    }

    /// Text shares may include a title plus one URL. Never turn arbitrary text
    /// into a search query or silently invent a scheme/hostname.
    public static func fromSharedText(_ text: String) throws -> URL {
        if let direct = try? validate(text) { return direct }
        guard text.utf8.count <= 16_384 else { throw SharedArticleError.invalidURL }
        let detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let matches = detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches {
            if let range = Range(match.range, in: text), let url = try? validate(String(text[range])) { return url }
        }
        throw SharedArticleError.invalidURL
    }
}

public struct SharedArticleEnvelope: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let version: Int
    public let url: URL
    public let title: String?
    public let createdAt: Date
    public init(url: URL, title: String? = nil, at date: Date = .now) throws {
        id = UUID(); version = 1; self.url = try SharedArticleURL.validate(url.absoluteString)
        self.title = title.map { String($0.prefix(500)) }; createdAt = date
    }
}

/// Immutable one-file-per-share queue. Atomic writes and unique names avoid
/// read/modify/write races between extensions. Acknowledgement deletes only the
/// imported envelope, never another share arriving during main-app import.
public struct SharedArticleInbox: Sendable {
    public let directory: URL?
    public init(directory: URL?) { self.directory = directory }

    /// Opt-in only. The signing service must provision the same App Group for
    /// both targets and set this Info key. No guessed or author-owned group ID.
    public static func configured(bundle: Bundle = .main) -> Self {
        guard let group = bundle.object(forInfoDictionaryKey: "NookieAppGroupIdentifier") as? String,
              group.hasPrefix("group."), !group.contains("$("),
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            return Self(directory: nil)
        }
        return Self(directory: container.appendingPathComponent("Nookie/ArticleInbox", isDirectory: true))
    }

    public func enqueue(_ value: SharedArticleEnvelope) throws {
        guard let directory else { throw SharedArticleError.unavailableContainer }
        _ = try SharedArticleURL.validate(value.url.absoluteString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(value.id.uuidString + ".json")
        try JSONEncoder().encode(value).write(to: target, options: .atomic)
    }

    public func pending() throws -> [SharedArticleEnvelope] {
        let scan = try scanPending()
        guard scan.invalidCount == 0 else { throw SharedArticleError.invalidEnvelope }
        return scan.items
    }

    public func scanPending() throws -> (items: [SharedArticleEnvelope], invalidCount: Int) {
        guard let directory else { return ([], 0) }
        guard FileManager.default.fileExists(atPath: directory.path) else { return ([], 0) }
        var invalidCount = 0
        let items = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .prefix(100).compactMap { file -> SharedArticleEnvelope? in
                do {
                guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 32_768 else {
                    throw SharedArticleError.invalidEnvelope
                }
                let value = try JSONDecoder().decode(SharedArticleEnvelope.self, from: Data(contentsOf: file))
                guard value.version == 1, file.deletingPathExtension().lastPathComponent == value.id.uuidString else {
                    throw SharedArticleError.invalidEnvelope
                }
                _ = try SharedArticleURL.validate(value.url.absoluteString)
                return value
                } catch { invalidCount += 1; return nil }
            }.sorted { $0.createdAt < $1.createdAt }
        return (items, invalidCount)
    }

    public func acknowledge(_ value: SharedArticleEnvelope) throws {
        guard let directory else { throw SharedArticleError.unavailableContainer }
        try FileManager.default.removeItem(at: directory.appendingPathComponent(value.id.uuidString + ".json"))
    }
}

public struct SharedArticleImportResult: Equatable, Sendable {
    public var imported = 0
    public var failed = 0
    public var invalid = 0
}

@MainActor
public enum SharedArticleImport {
    private static var activeDirectories: Set<URL> = []
    /// Acknowledge only after the main app has durably accepted the URL. A
    /// crash/retry can re-import an envelope, so acceptance must be idempotent.
    public static func drain(_ inbox: SharedArticleInbox,
        accept: (SharedArticleEnvelope) async throws -> Void) async throws -> SharedArticleImportResult {
        guard let directory = inbox.directory else { return SharedArticleImportResult() }
        guard activeDirectories.insert(directory).inserted else { throw SharedArticleError.importInProgress }
        defer { activeDirectories.remove(directory) }
        let scan = try inbox.scanPending()
        var result = SharedArticleImportResult(); result.invalid = scan.invalidCount
        for item in scan.items {
            if Task.isCancelled { break }
            do {
                try await accept(item)
                try inbox.acknowledge(item)
                result.imported += 1
            } catch { result.failed += 1 }
        }
        return result
    }
}
