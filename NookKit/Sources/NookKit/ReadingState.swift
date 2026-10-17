import Foundation
import Observation
import SwiftUI

public enum ReadingStatePolicy {
    public static let resumeThreshold = 0.05
    public static let completedThreshold = 0.95
    public static let writeInterval: TimeInterval = 5
}

public struct ArticleReadingState: Codable, Equatable, Sendable {
    public let identity: String
    public var articleID: String
    public var canonicalURL: URL
    public var lastOpenedAt: Date
    public var readingProgress: Double
    public var lastVisibleBlockID: String?
    public var presentationAnchorID: String?
    public var preferredReaderMode: String
    public var isRead: Bool
    public var mode: BlockReaderMode { BlockReaderMode(rawValue: preferredReaderMode) ?? .bilingual }
}

public struct ReaderReadingAnchor: Equatable, Sendable, Hashable {
    public let blockID: String
    public let presentationID: String
    public init(blockID: String, presentationID: String? = nil) {
        self.blockID = blockID; self.presentationID = presentationID ?? blockID
    }
}

public enum ReaderResumePosition {
    /// Prefer the exact source block; fragment ID is just an optional finer
    /// anchor. Text edits/cleanup fall back to a proportional source position.
    public static func anchor(for state: ArticleReadingState?, in anchors: [ReaderReadingAnchor]) -> ReaderReadingAnchor? {
        guard let state, state.readingProgress >= ReadingStatePolicy.resumeThreshold, !anchors.isEmpty else { return nil }
        if let exact = anchors.first(where: {
            $0.blockID == state.lastVisibleBlockID && $0.presentationID == state.presentationAnchorID
        }) { return exact }
        if let block = anchors.first(where: { $0.blockID == state.lastVisibleBlockID }) { return block }
        let progress = min(1, max(0, state.readingProgress.isFinite ? state.readingProgress : 0))
        return anchors[min(anchors.count - 1, Int(progress * Double(anchors.count - 1)))]
    }
}

@MainActor @Observable
public final class ReadingStateStore {
    public static let shared = ReadingStateStore()
    public private(set) var entries: [String: ArticleReadingState] = [:]
    public private(set) var errorMessage: String?
    public private(set) var writeCount = 0
    @ObservationIgnored private let file: URL?
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var readable = true
    @ObservationIgnored private var lastWrite = Date.distantPast
    private struct File: Codable { var version = 1; var entries: [String: ArticleReadingState] }

    public init(file: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first?.appendingPathComponent("Nook/ReadingState/state.json")) {
        self.file = file
        guard let file, FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let value = try JSONDecoder().decode(File.self, from: Data(contentsOf: file))
            guard value.version == 1 else { throw CocoaError(.fileReadUnknown) }
            entries = value.entries
        } catch { readable = false; errorMessage = "阅读位置读取失败，原文件未覆盖。" }
    }

    public func state(for article: Article) -> ArticleReadingState? { entries[StableArticleIdentity.key(article)] }

    @discardableResult public func opened(_ article: Article, at now: Date = .now) -> ArticleReadingState {
        let key = StableArticleIdentity.key(article)
        var value = entries[key] ?? ArticleReadingState(identity: key, articleID: article.id,
            canonicalURL: StableArticleIdentity.canonicalURL(article.url), lastOpenedAt: now, readingProgress: 0,
            lastVisibleBlockID: nil, presentationAnchorID: nil, preferredReaderMode: BlockReaderMode.bilingual.rawValue,
            isRead: article.isRead)
        value.articleID = article.id; value.lastOpenedAt = now; value.isRead = article.isRead
        guard readable else { return value }
        entries[key] = value; dirty = true; flush(at: now)
        return value
    }

    public func update(_ article: Article, progress: Double, anchor: ReaderReadingAnchor?,
                       mode: BlockReaderMode, at now: Date = .now) {
        guard readable, var value = state(for: article), progress.isFinite else { return }
        // Percent quantization keeps geometry changes observation-light too.
        value.readingProgress = (min(1, max(0, progress)) * 100).rounded(.down) / 100
        value.lastVisibleBlockID = anchor?.blockID
        value.presentationAnchorID = anchor?.presentationID
        value.preferredReaderMode = mode.rawValue
        guard value != entries[value.identity] else { return }
        entries[value.identity] = value; dirty = true
        if now.timeIntervalSince(lastWrite) >= ReadingStatePolicy.writeInterval { flush(at: now) }
    }

    public func setMode(_ mode: BlockReaderMode, for article: Article) {
        guard readable, var value = state(for: article), value.preferredReaderMode != mode.rawValue else { return }
        value.preferredReaderMode = mode.rawValue
        entries[value.identity] = value; dirty = true
    }

    public func setRead(_ read: Bool, for article: Article) {
        guard readable, var value = state(for: article), value.isRead != read else { return }
        value.isRead = read; entries[value.identity] = value; dirty = true; flush()
    }

    public func flush(at now: Date = .now) {
        guard readable, dirty else { return }
        do {
            if let file {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(File(entries: entries)).write(to: file, options: .atomic)
            }
            dirty = false; lastWrite = now; writeCount += 1; errorMessage = nil
        } catch { errorMessage = "阅读位置保存失败，请检查本机存储空间。" }
    }
}

/// Presentation-only access. No translation request, cache or schema changes.
extension BlockReaderTranslationController {
    public var readingAnchors: [ReaderReadingAnchor] {
        guard let prepared else { return [] }
        func collect(_ nodes: [BlockReaderPresentationNode]) -> [ReaderReadingAnchor] {
            nodes.flatMap { node -> [ReaderReadingAnchor] in
                switch node {
                case .group(let group): return [.init(blockID: group.blockID, presentationID: group.id)]
                case .quote(let children): return collect(children)
                case .list(_, let items): return items.flatMap(collect)
                case .unchanged, .photoCredit: return []
                }
            }
        }
        return collect(BlockReaderPresentation.nodes(prepared.nodes, translations: translatedHTML, templates: presentationTranslations))
    }
}

/// Only structured text groups participate. Media stays rendered once; geometry
/// is relative to the Reader viewport, never persisted as a pixel offset.
public struct ReaderAnchorFrame: Equatable, Sendable {
    public let anchor: ReaderReadingAnchor
    public let minY: CGFloat
    public let maxY: CGFloat
    public init(anchor: ReaderReadingAnchor, minY: CGFloat, maxY: CGFloat) {
        self.anchor = anchor; self.minY = minY; self.maxY = maxY
    }
}
public struct ReaderAnchorFramesKey: PreferenceKey {
    public static let defaultValue: [ReaderAnchorFrame] = []
    public static func reduce(value: inout [ReaderAnchorFrame], nextValue: () -> [ReaderAnchorFrame]) {
        value.append(contentsOf: nextValue())
    }
}

/// Reader-local bookkeeping survives body evaluations without publishing every
/// scroll sample. Position is only recorded after a genuine user scroll.
public final class ReaderResumeSession {
    public var articleID: String?
    public var saved: ArticleReadingState?
    public var restored = false
    public var userScrolled = false
    public var manuallyMarkedUnread = false
    public var progress: Double = 0
    public var visible: ReaderReadingAnchor?
    public init() {}
    public func begin(articleID: String, saved: ArticleReadingState?) {
        self.articleID = articleID; self.saved = saved; restored = false; userScrolled = false
        manuallyMarkedUnread = false
        progress = saved?.readingProgress ?? 0
        visible = nil
    }
}
