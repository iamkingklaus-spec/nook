import Foundation

/// A confidence assessment, never a claim that a publisher supplied every word.
public enum ReaderContentQuality: String, Codable, Sendable {
    case fullCandidate, possiblySummary, summaryOnly, unavailable

    public var notice: String? {
        switch self {
        case .summaryOnly: "当前仅获取到 RSS 摘要，未能提取完整正文。"
        case .possiblySummary: "当前内容可能仅为摘要。"
        default: nil
        }
    }

    var rank: Int {
        switch self { case .fullCandidate: 3; case .possiblySummary: 2; case .summaryOnly: 1; case .unavailable: 0 }
    }
}

public struct ReaderQualityAssessment: Equatable, Sendable {
    public let quality: ReaderContentQuality
    public let characterCount: Int
    public let paragraphCount: Int
    public let summarySimilarity: Double
    public let hasAccessPrompt: Bool
    public let semanticBlockCount: Int
}

enum ReaderQualityEvaluator {
    static let version = 1
    enum ParserStatus: Equatable, Sendable { case notRun, succeeded, failed }

    static func assess(html: String, summary: String, source: ArticleContentSource,
                       parserStatus: ParserStatus, declaredFullContent: Bool = true) -> ReaderQualityAssessment {
        let blocks = HTMLContentParser.parse(html, baseURL: nil)
        var paragraphs: [String] = []
        var semantic = 0
        var bodyBlocks = 0
        var linkCharacters = 0
        func visit(_ blocks: [HTMLContentBlock]) {
            for block in blocks {
                switch block {
                case .heading(_, let html):
                    let text = HTMLContentParser.plainText(html)
                    if !text.isEmpty { paragraphs.append(text); semantic += 1 }
                case .text(let html):
                    let fragments = html.replacingOccurrences(of: "(?is)</(?:p|div)>|<br\\s*/?>",
                        with: "\n", options: .regularExpression).components(separatedBy: "\n")
                    let texts = fragments.map(HTMLContentParser.plainText).filter { !$0.isEmpty }
                    paragraphs.append(contentsOf: texts)
                    semantic += texts.count
                    bodyBlocks += texts.count
                    let regex = try! NSRegularExpression(pattern: "(?is)<a\\b[^>]*>(.*?)</a>")
                    let ns = html as NSString
                    for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
                        linkCharacters += HTMLContentParser.plainText(ns.substring(with: match.range(at: 1))).count
                    }
                case .blockquote(let children): visit(children)
                case .list(_, let items): for item in items { visit(item) }
                case .codeBlock(let code, _):
                    if !code.isEmpty { paragraphs.append(code); semantic += 1; bodyBlocks += 1 }
                case .table(let table):
                    let text = table.rows.flatMap(\.cells).map { HTMLContentParser.plainText($0.html) }.joined(separator: " ")
                    if !text.isEmpty { paragraphs.append(text); semantic += 1; bodyBlocks += 1 }
                default: break
                }
            }
        }
        visit(blocks)
        let plain = paragraphs.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = normalize(plain)
        let baseline = normalize(HTMLContentParser.plainText(summary))
        let similarity = Self.similarity(normalized, baseline)
        let gatePhrases = ["subscribe to continue", "subscribe to read", "sign in to read", "sign in to continue",
                           "log in to read", "log in to continue", "login to continue", "unlock this article",
                           "already a subscriber", "this article is for subscribers", "subscription required",
                           "订阅后阅读全文", "登录后继续阅读", "登录后阅读", "付费后阅读"]
        let gateParagraphs = paragraphs.filter { paragraph in
            let text = paragraph.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            let gateLabels = ["sign in", "log in", "login", "subscribe", "please sign in", "please log in"]
            return gateLabels.contains(text) || text.count < 320 && gatePhrases.contains { text.hasPrefix($0) }
        }
        let hasPasswordForm = html.range(of: "(?is)<input\\b[^>]*type\\s*=\\s*['\"]?password", options: .regularExpression) != nil
        let accessPrompt = !gateParagraphs.isEmpty || hasPasswordForm
        let nonGate = paragraphs.filter { !gateParagraphs.contains($0) }.joined(separator: " ")
        let isTeaser = ["continue reading", "read the full article", "阅读全文", "阅读原文"].contains {
            plain.lowercased().hasSuffix($0) || plain.lowercased().hasSuffix($0 + "…")
        }
        let comparableToSummary = !baseline.isEmpty && similarity >= 0.86 &&
            normalized.count <= max(baseline.count + 32, Int(Double(baseline.count) * 1.3))
        let quality: ReaderContentQuality
        if normalized.isEmpty || (accessPrompt && (normalize(nonGate).count < 80 || hasPasswordForm && semantic < 2)) {
            quality = .unavailable
        } else if source == .rssDescription {
            quality = .summaryOnly
        } else if parserStatus == .failed || accessPrompt || isTeaser || comparableToSummary ||
                    (plain.count > 0 && Double(linkCharacters) / Double(plain.count) > 0.8) {
            quality = .possiblySummary
        } else if bodyBlocks > 0 && (parserStatus == .succeeded || declaredFullContent) {
            // No minimum word/character threshold: a short standalone news brief
            // with successful parsing and no teaser evidence is still a candidate.
            quality = .fullCandidate
        } else {
            quality = .possiblySummary
        }
        return ReaderQualityAssessment(quality: quality, characterCount: plain.count,
            paragraphCount: paragraphs.count, summarySimilarity: similarity,
            hasAccessPrompt: accessPrompt, semanticBlockCount: semantic)
    }

    private static func normalize(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    private static func similarity(_ lhs: String, _ rhs: String) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        if lhs == rhs { return 1 }
        func grams(_ text: String) -> Set<String> {
            let characters = Array(text.prefix(40_000))
            guard characters.count >= 3 else { return [text] }
            return Set((0..<(characters.count - 2)).map { String(characters[$0...($0 + 2)]) })
        }
        let a = grams(lhs), b = grams(rhs)
        return 2 * Double(a.intersection(b).count) / Double(a.count + b.count)
    }
}

struct ReaderContentCandidate: Sendable {
    let html: String
    let source: ArticleContentSource
    let assessment: ReaderQualityAssessment
    let extracted: ReaderModeExtractor.Extracted?
    let isCached: Bool
    var engine: ReaderParserEngine? { extracted?.engine }

    init(html: String, source: ArticleContentSource, summary: String,
         extracted: ReaderModeExtractor.Extracted? = nil, isCached: Bool = false,
         declaredFullContent: Bool = true, knownQuality: ReaderContentQuality? = nil) {
        self.html = html
        self.source = source
        self.extracted = extracted
        self.isCached = isCached
        let evaluated = ReaderQualityEvaluator.assess(html: html, summary: summary, source: source,
            parserStatus: source == .extractedReaderContent ? .succeeded : .notRun,
            declaredFullContent: declaredFullContent)
        assessment = ReaderQualityAssessment(quality: knownQuality ?? evaluated.quality,
            characterCount: evaluated.characterCount, paragraphCount: evaluated.paragraphCount,
            summarySimilarity: evaluated.summarySimilarity, hasAccessPrompt: evaluated.hasAccessPrompt,
            semanticBlockCount: evaluated.semanticBlockCount)
    }
}

/// Orchestrates the two existing engines through an injectable boundary. It has
/// no Gemini dependency and never starts translation or changes article metadata.
@MainActor
enum ReaderContentResolver {
    struct Resolution: Sendable {
        let candidate: ReaderContentCandidate?
        let attempts: [ReaderParserEngine]
        let originalGone: Bool
    }

    static func rssCandidates(for article: Article) -> [ReaderContentCandidate] {
        var result: [ReaderContentCandidate] = []
        for source in article.sourceContents where source.source == .rssFullContent {
            let html = source.format == .plainText ? escapedParagraph(source.content) : source.content
            result.append(ReaderContentCandidate(html: html, source: .rssFullContent, summary: article.summary,
                declaredFullContent: source.quality != .partial && source.quality != .failed && source.quality != .empty))
        }
        if result.isEmpty, let html = article.contentHTML {
            result.append(ReaderContentCandidate(html: html,
                source: article.contentSource == .rssDescription ? .rssDescription : .rssFullContent,
                summary: article.summary, declaredFullContent: article.contentSource == .rssFullContent))
        }
        if result.isEmpty, article.contentSource == .rssFullContent, !article.bodyParagraphs.isEmpty {
            result.append(ReaderContentCandidate(html: article.bodyParagraphs.map(escapedParagraph).joined(),
                source: .rssFullContent, summary: article.summary))
        }
        let description = article.sourceContents.first { $0.source == .rssDescription }
        let summaryHTML = description.map { $0.format == .plainText ? escapedParagraph($0.content) : $0.content }
            ?? escapedParagraph(article.summary)
        result.append(ReaderContentCandidate(html: summaryHTML, source: .rssDescription, summary: article.summary))
        return result
    }

    static func resolve(article: Article, cached: ReaderContentCandidate? = nil,
                        preferred: ReaderParserEngine, forceParser: Bool = false,
                        extract: (ReaderParserEngine) async -> ReaderModeExtractor.Outcome) async -> Resolution {
        let rss = rssCandidates(for: article)
        if !forceParser {
            if let cached, cached.assessment.quality == .fullCandidate {
                return Resolution(candidate: cached, attempts: [], originalGone: false)
            }
            if let full = rss.first(where: { $0.assessment.quality == .fullCandidate }) {
                return Resolution(candidate: full, attempts: [], originalGone: false)
            }
        }
        var candidates = rss + [cached].compactMap { $0 }
        var attempted: [ReaderParserEngine] = []
        var gone = false
        for engine in [preferred, preferred.other] where !attempted.contains(engine) {
            if Task.isCancelled { break }
            attempted.append(engine)
            let outcome = await extract(engine)
            if Task.isCancelled { break }
            switch outcome {
            case .success(let extracted):
                if !attempted.contains(extracted.engine) { attempted.append(extracted.engine) }
                let candidate = ReaderContentCandidate(html: extracted.html, source: .extractedReaderContent,
                    summary: article.summary, extracted: extracted)
                candidates.insert(candidate, at: 0)
                if candidate.assessment.quality == .fullCandidate {
                    return Resolution(candidate: candidate, attempts: attempted, originalGone: false)
                }
            case .gone: gone = true
            case .failed, .timedOut: break
            }
            if gone { break }
        }
        let selected = candidates.filter { $0.assessment.quality != .unavailable }.sorted { a, b in
            if a.assessment.quality.rank != b.assessment.quality.rank {
                return a.assessment.quality.rank > b.assessment.quality.rank
            }
            if a.isCached != b.isCached, a.assessment.quality == .fullCandidate { return a.isCached }
            return a.assessment.characterCount > b.assessment.characterCount
        }.first
        return Resolution(candidate: selected, attempts: attempted, originalGone: gone)
    }

    private static func escapedParagraph(_ value: String) -> String {
        "<p>" + value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") + "</p>"
    }
}
