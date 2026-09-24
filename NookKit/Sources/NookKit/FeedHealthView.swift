import SwiftUI

public struct FeedHealthListView: View {
    private let feeds: [Feed]
    @State private var diagnostics = FeedHealthDiagnostics.shared
    public init(feeds: [Feed]) { self.feeds = feeds }

    public var body: some View {
        List(feeds) { feed in
            NavigationLink {
                FeedHealthView(feed: feed)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(feed.displayTitle)
                    FeedHealthStatus(report: diagnostics.reports[feed.feedURL])
                        .font(.caption)
                }
            }
        }
        .navigationTitle("Feed Health / 订阅源诊断")
        .overlay { if feeds.isEmpty { Text("没有可检测的订阅源").foregroundStyle(.secondary) } }
    }
}

public struct FeedHealthView: View {
    private let feed: Feed
    private let testOnOpen: Bool
    @State private var diagnostics = FeedHealthDiagnostics.shared
    private var report: FeedHealthReport? { diagnostics.reports[feed.feedURL] }
    private var busy: Bool { diagnostics.isBusy(feed.feedURL) }

    public init(feed: Feed, testOnOpen: Bool = false) {
        self.feed = feed
        self.testOnOpen = testOnOpen
    }

    public var body: some View {
        Form {
            Section {
                FeedHealthStatus(report: report)
                if let report {
                    Text("\(report.itemCount) articles · \(report.format.rawValue)")
                    HStack {
                        Text("Checked / 检测于")
                        Text(report.checkedAt, style: .relative)
                    }.font(.caption).foregroundStyle(.secondary)
                    if let error = report.errorReason { Text(error).font(.caption).textSelection(.enabled) }
                }
            } header: { Text(feed.displayTitle) }

            Section("Feed 请求与文章链接") {
                LabeledContent("Requested URL") { Text(feed.feedURL.absoluteString).textSelection(.enabled) }
                if let report {
                    LabeledContent("Final URL", value: report.finalURL?.absoluteString ?? "—")
                    LabeledContent("HTTP", value: report.httpStatus.map(String.init) ?? "—")
                    if report.parseResult == .success {
                        LabeledContent("有效文章链接", value: "\(report.validArticleURLCount)")
                        LabeledContent("缺失链接", value: "\(report.missingArticleURLCount)")
                        LabeledContent("无效链接", value: "\(report.invalidArticleURLCount)")
                        LabeledContent("首页 / fallback 链接", value: "\(report.homepageFallbackCount)")
                    }
                    ForEach(report.discoveredFeedURLs, id: \.self) { url in
                        LabeledContent("网页声明的其他 Feed（未检测）", value: url.absoluteString)
                    }
                }
                Text("基础检测仅检查链接格式与来源，不代表文章 URL 可达。不会自动修改订阅地址。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Article extraction / 正文抽样") {
                Label {
                    Text(report?.extractionDescription ?? "正文未测试")
                } icon: {
                    Image(systemName: report?.extractionSamples == nil ? "minus.circle" : "doc.text.magnifyingglass")
                        .foregroundStyle(extractionColor)
                }
                    .accessibilityLabel(report?.extractionDescription ?? "正文未测试")
                if let samples = report?.extractionSamples {
                    ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                        VStack(alignment: .leading, spacing: 4) {
                            Link(sample.articleURL.absoluteString, destination: sample.articleURL)
                                .lineLimit(2)
                            Text(sample.quality.rawValue).font(.caption)
                            Text(sample.checkedAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                            if let reason = sample.errorReason { Text(reason).font(.caption).foregroundStyle(.secondary) }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                Text("仅按需抽样最多 3 篇最近文章，逐篇检测。结果不代表整个媒体；不计算成功率。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Button("Test Feed / 检测订阅源") { Task { await diagnostics.testFeed(feed.feedURL) } }
                    .disabled(busy)
                Button("Test Article Extraction / 检测正文抽样") {
                    Task { await diagnostics.testArticleExtraction(feed.feedURL) }
                }
                .disabled(busy || diagnostics.samplingURL != nil || report?.canSample != true)
                Button("Retry / 重新检测") { Task { await diagnostics.testFeed(feed.feedURL, force: true) } }
                    .disabled(busy)
                if report?.extractionSamples != nil {
                    Button("Retry Article Extraction / 重试正文抽样") {
                        Task { await diagnostics.testArticleExtraction(feed.feedURL, force: true) }
                    }.disabled(busy || diagnostics.samplingURL != nil)
                }
                if busy { ProgressView("正在检测，可关闭此页继续阅读…") }
            } footer: {
                Text("诊断仅在本机内存短期保存。正常结果缓存 5 分钟，请求或解析错误缓存 30 秒；重试可立即重新请求。不会改变分类、已读、收藏或正常刷新时间。")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Feed Health")
        .task { if testOnOpen { await diagnostics.testFeed(feed.feedURL) } }
    }

    private var extractionColor: Color {
        guard let samples = report?.extractionSamples, !samples.isEmpty else { return .secondary }
        return samples.allSatisfy { $0.quality == .fullCandidate } ? .green : .yellow
    }
}

private struct FeedHealthStatus: View {
    let report: FeedHealthReport?
    private var severity: FeedHealthReport.Severity { report?.severity ?? .untested }
    private var text: String {
        let base = report?.feedDescription ?? "Feed 尚未检测"
        return severity == .warning ? base + " · 文章链接或正文抽样存在风险" : base
    }
    private var color: Color {
        switch severity { case .normal: .green; case .warning: .yellow; case .failure: .red; case .untested: .secondary }
    }
    private var symbol: String {
        switch severity { case .normal: "checkmark.circle"; case .warning: "exclamationmark.triangle";
        case .failure: "xmark.circle"; case .untested: "minus.circle" }
    }
    var body: some View {
        Label { Text(text) } icon: { Image(systemName: symbol).foregroundStyle(color) }
            .accessibilityElement(children: .ignore).accessibilityLabel(text)
    }
}

/// Sheet wrapper shared by the two feed-management context menus.
public struct FeedHealthSheet: View {
    private let feed: Feed
    @Environment(\.dismiss) private var dismiss
    public init(feed: Feed) { self.feed = feed }
    public var body: some View {
        NavigationStack {
            FeedHealthView(feed: feed, testOnOpen: true)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 540, minHeight: 560)
        #endif
    }
}
