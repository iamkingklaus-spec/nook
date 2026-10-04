import SwiftUI

/// Computed off-main when a Reader's bounded candidate set changes. No AI on article open.
public struct StoryContextView: View {
    private let article: Article
    private let candidates: [Article]
    private let onOpen: (Article) -> Void
    @State private var cluster: EventCluster?
    private enum ContextTab { case background, timeline, coverage }
    @State private var tab = ContextTab.coverage
    public init(article: Article, articles: [Article], onOpen: @escaping (Article) -> Void) {
        self.article = article
        candidates = StoryClustering.candidates(for: article, in: articles)
        self.onOpen = onOpen
    }
    private var inputKey: String { EventCluster(members: [article] + candidates).fingerprint }
    public var body: some View {
        Group {
            if let cluster {
                VStack(alignment: .leading, spacing: NookTheme.Space.card) {
                    Divider()
                    Text("Story Context").font(NookTypography.sectionTitle)
                    Picker("文章上下文", selection: $tab) {
                        Text("背景").tag(ContextTab.background)
                        Text("时间线").tag(ContextTab.timeline)
                        Text("其他报道").tag(ContextTab.coverage)
                    }.pickerStyle(.segmented)
                    if tab == .background {
                        Text("想了解人物、机构或政策？开启英语学习，在英文正文中选中名称，点击“背景”。")
                            .foregroundStyle(NookTheme.textSecondary)
                        Text("仅在你点选后生成；本文关系与一般背景分别展示。")
                            .font(NookTypography.caption).foregroundStyle(NookTheme.textSecondary)
                    } else if tab == .timeline {
                        StoryTimelinePane(cluster: cluster, articleID: article.id, onOpen: onOpen)
                    } else {
                    Text("另有 \(Set(cluster.related(to: article).map { $0.url.host ?? "" }).count) 家来源报道相近事件")
                        .font(NookTypography.caption).foregroundStyle(NookTheme.textSecondary)
                    ForEach(cluster.related(to: article)) { item in
                        Button { onOpen(item) } label: {
                            VStack(alignment: .leading, spacing: NookTheme.Space.tight) {
                                Text(item.url.host ?? "").font(NookTypography.caption).foregroundStyle(NookTheme.textSecondary)
                                Text(item.title).font(NookTypography.storyTitle).foregroundStyle(NookTheme.textPrimary)
                            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }.buttonStyle(NookContentButtonStyle())
                    }
                    }
                }
            }
        }
        .task(id: inputKey) {
            let current = article, pool = candidates
            let result = await Task.detached(priority: .utility) { StoryClustering.cluster(for: current, candidates: pool) }.value
            guard !Task.isCancelled else { return }
            cluster = result
        }
    }
}

private struct StoryTimelinePane: View {
    let cluster: EventCluster
    let articleID: String
    let onOpen: (Article) -> Void
    @State private var controller = StoryTimelineController()
    @State private var retry = 0
    @State private var selectedID: String?
    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Space.card) {
            if controller.loading { ProgressView("正在整理有来源依据的时间线…") }
            if let nodes = controller.nodes {
                if nodes.isEmpty { Text("现有材料不足以形成可靠时间线。") }
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(nodes) { node in
                            Button { selectedID = node.id } label: {
                                VStack(alignment: .leading, spacing: NookTheme.Space.inline) {
                                    Text(node.date).font(NookTypography.caption).monospacedDigit()
                                    HStack(spacing: 0) {
                                        Circle().fill(node.sourceArticleIDs.contains(articleID) ? NookTheme.accentPrimary : NookTheme.textTertiary).frame(width: 8, height: 8)
                                        Rectangle().fill(NookTheme.divider).frame(height: 0.5)
                                    }
                                    Text(node.title).font(NookTypography.storyTitle)
                                    if node.sourceArticleIDs.contains(articleID) { Text("当前文章").font(NookTypography.caption) }
                                }.foregroundStyle(NookTheme.textPrimary).frame(width: 190, alignment: .leading).padding(.trailing, 16)
                            }.buttonStyle(NookContentButtonStyle()).accessibilityHint("展开节点及来源")
                        }
                    }.padding(.vertical, 8)
                }
                if let selected = nodes.first(where: { $0.id == selectedID }) ?? nodes.first(where: { $0.sourceArticleIDs.contains(articleID) }) ?? nodes.first {
                    VStack(alignment: .leading, spacing: NookTheme.Space.inline) {
                        Text(selected.date).font(NookTypography.caption).foregroundStyle(NookTheme.textSecondary)
                        Text(selected.title).font(NookTypography.storyTitle)
                        Text(selected.shortSummary)
                        ForEach(selected.sourceArticleIDs, id: \.self) { id in
                            if let source = cluster.members.first(where: { $0.id == id }) {
                                Button { onOpen(source) } label: { Label(source.url.host ?? source.title, systemImage: "arrow.up.right") }
                                    .buttonStyle(NookActionStyle(.quiet))
                            }
                        }
                    }.padding(NookTheme.Space.card).nookCard()
                }
                Text("AI 归纳 · 按报道发布日期整理，不代表事件发生时间；请核对原文。")
                    .font(NookTypography.caption).foregroundStyle(NookTheme.textSecondary)
            }
            if let message = controller.message { Text(message).font(NookTypography.caption) }
            if !controller.loading && controller.nodes == nil { Button("重试时间线") { retry += 1 }.buttonStyle(NookActionStyle()) }
        }
        .task(id: TimelineProtocol.key(cluster, model: .flashLite) + String(retry)) { await controller.load(cluster) }
        .onDisappear { controller.cancel() }
    }
}
