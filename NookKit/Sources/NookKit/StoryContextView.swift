import SwiftUI

/// Computed off-main when a Reader's bounded candidate set changes. No AI on article open.
public struct StoryContextView: View {
    private let article: Article
    private let candidates: [Article]
    private let onOpen: (Article) -> Void
    @State private var cluster: EventCluster?
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
                    Text("More coverage / 其他报道").font(NookTypography.sectionTitle)
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
        .task(id: inputKey) {
            let current = article, pool = candidates
            let result = await Task.detached(priority: .utility) { StoryClustering.cluster(for: current, candidates: pool) }.value
            guard !Task.isCancelled else { return }
            cluster = result
        }
    }
}
