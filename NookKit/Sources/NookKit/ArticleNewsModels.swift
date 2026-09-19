import CryptoKit
import Foundation

/// Editorial news sections, independent of feed folders and user category IDs.
public enum NewsCategory: String, Codable, CaseIterable, Sendable {
    case world, business, technology, science, culture, longReads, other
}

public struct NewsCategoryProvenance: Codable, Hashable, Sendable {
    public enum Source: String, Codable, Sendable { case feed, rssTag, rule, manual }
    public var source: Source
    public var ruleVersion: String?

    public init(source: Source, ruleVersion: String? = nil) {
        self.source = source
        self.ruleVersion = ruleVersion
    }
}

public enum HeroImageProvenance: String, Codable, Sendable {
    case enclosure, mediaContent, mediaThumbnail, extractedReader, manual
}

/// All feed image candidates survive parsing; the selected hero is separate.
public struct ArticleImageMetadata: Codable, Hashable, Sendable {
    public var url: URL
    public var provenance: HeroImageProvenance
    public var mimeType: String?

    public init(url: URL, provenance: HeroImageProvenance, mimeType: String? = nil) {
        self.url = url
        self.provenance = provenance
        self.mimeType = mimeType
    }
}

/// Names describe where content came from, not whether it is actually complete.
public enum ArticleContentSource: String, Codable, Sendable {
    case rssFullContent, rssDescription, extractedReaderContent
}

public enum ArticleContentQuality: String, Codable, Sendable {
    case unknown, complete, partial, empty, failed
}

public enum ArticleContentFormat: String, Codable, Sendable {
    case plainText, html, xhtml
}

/// Raw feed/reader payloads are body data, not list metadata. No quality heuristic
/// or extraction/translation request is run by constructing this value.
public struct ArticleSourceContent: Codable, Hashable, Sendable {
    public var source: ArticleContentSource
    public var content: String
    public var format: ArticleContentFormat
    public var sourceElement: String?
    public var quality: ArticleContentQuality

    public init(source: ArticleContentSource, content: String, format: ArticleContentFormat,
                sourceElement: String? = nil, quality: ArticleContentQuality = .unknown) {
        self.source = source
        self.content = content
        self.format = format
        self.sourceElement = sourceElement
        self.quality = quality
    }
}

/// Immutable source blocks. Hashes never use Swift's process-randomized Hasher.
/// Equal blocks are distinguished by their occurrence among equal blocks, not
/// their absolute position, so inserting an unrelated paragraph preserves IDs.
public struct ArticleBlock: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case paragraph, heading, listItem, quote, code, image, divider, other
    }

    public let kind: Kind
    public let sourceContent: String
    public let format: ArticleContentFormat
    public let occurrence: Int
    public var contentHash: String {
        ArticleDocument.digest(["block-v1", kind.rawValue, format.rawValue, sourceContent])
    }
    public var id: String { "\(contentHash):\(occurrence)" }

    public init(kind: Kind, sourceContent: String, format: ArticleContentFormat = .plainText,
                occurrence: Int = 0) {
        self.kind = kind
        self.sourceContent = sourceContent
        self.format = format
        self.occurrence = max(0, occurrence)
    }

    enum CodingKeys: String, CodingKey { case kind, sourceContent, format, occurrence, id, contentHash }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(kind: try c.decode(Kind.self, forKey: .kind),
                  sourceContent: try c.decode(String.self, forKey: .sourceContent),
                  format: try c.decodeIfPresent(ArticleContentFormat.self, forKey: .format) ?? .plainText,
                  occurrence: try c.decodeIfPresent(Int.self, forKey: .occurrence) ?? 0)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(sourceContent, forKey: .sourceContent)
        try c.encode(format, forKey: .format)
        try c.encode(occurrence, forKey: .occurrence)
        try c.encode(id, forKey: .id)
        try c.encode(contentHash, forKey: .contentHash)
    }
}

/// A versioned translation input, not a translation or a DOM parser. Block IDs
/// are scoped to an article; documentHash captures order as well as source text.
public struct ArticleDocument: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1
    public let schemaVersion: Int
    public let source: ArticleContentSource
    public let blocks: [ArticleBlock]
    public var documentHash: String {
        Self.digest(["document", String(schemaVersion), source.rawValue] + blocks.map(\.id))
    }

    public init(source: ArticleContentSource, blocks: [ArticleBlock]) {
        schemaVersion = Self.currentSchemaVersion
        self.source = source
        self.blocks = Self.canonicalBlocks(blocks)
    }

    private static func canonicalBlocks(_ blocks: [ArticleBlock]) -> [ArticleBlock] {
        var occurrences: [String: Int] = [:]
        return blocks.map { block in
            let occurrence = occurrences[block.contentHash, default: 0]
            occurrences[block.contentHash] = occurrence + 1
            return ArticleBlock(kind: block.kind, sourceContent: block.sourceContent,
                                format: block.format, occurrence: occurrence)
        }
    }

    // Length framing avoids ambiguous concatenations, including embedded NULs.
    static func digest(_ components: [String]) -> String {
        let framed = components.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(framed.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    enum CodingKeys: String, CodingKey { case schemaVersion, source, blocks, documentHash }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        source = try c.decode(ArticleContentSource.self, forKey: .source)
        blocks = Self.canonicalBlocks(try c.decode([ArticleBlock].self, forKey: .blocks))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(source, forKey: .source)
        try c.encode(blocks, forKey: .blocks)
        try c.encode(documentHash, forKey: .documentHash)
    }
}

extension Article {
    /// Restore the whole body envelope together, including future translation input.
    mutating func applyBody(_ body: ArticleBody) {
        bodyParagraphs = body.bodyParagraphs
        contentHTML = body.contentHTML
        sourceContents = body.sourceContents
        document = body.document
    }

    /// RSS refresh supplies new feed evidence, but no local news classification
    /// or extracted reader document. Preserve enrichment without retaining a
    /// stale RSS document when its underlying source has changed.
    mutating func preserveNewsEnrichment(from existing: Article) {
        if newsCategory == nil {
            newsCategory = existing.newsCategory
            newsCategoryProvenance = existing.newsCategoryProvenance
        }
        if subtitle == nil { subtitle = existing.subtitle }
        if feedItemGUID == nil { feedItemGUID = existing.feedItemGUID }
        if heroImageURL == nil || existing.heroImageProvenance == .manual {
            heroImageURL = existing.heroImageURL
            heroImageProvenance = existing.heroImageProvenance
        }
        if !sourceContents.contains(where: { $0.source == .extractedReaderContent }) {
            sourceContents += existing.sourceContents.filter { $0.source == .extractedReaderContent }
        }
        func sameSource(_ source: ArticleContentSource) -> Bool {
            guard let old = existing.sourceContents.first(where: { $0.source == source }),
                  let fresh = sourceContents.first(where: { $0.source == source }) else { return false }
            return old.content == fresh.content && old.format == fresh.format
        }
        if let source = contentSource, source == existing.contentSource, sameSource(source) {
            contentQuality = existing.contentQuality ?? contentQuality
        }
        if document == nil, let oldDocument = existing.document, sameSource(oldDocument.source) {
            document = oldDocument
        }
    }
}
