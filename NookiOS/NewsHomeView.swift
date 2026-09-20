import NookKit
import SwiftUI

/// One editorial surface for the phone stack and the iPad's middle column.
/// Projection work stays outside body and runs off the main actor.
struct NewsHomeView: View {
    @Bindable var store: ReaderStore
    var isReading = false
    var onOpen: (Article) -> Void
    var onExplore: () -> Void
    @Environment(TabBarChrome.self) private var tabChrome
    @Environment(TourCoordinator.self) private var tour
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var section: NewsHomeSection = .forYou
    @State private var editionDate = Date.now
    @State private var readSnapshot: [Article.ID: Bool] = [:]
    @State private var projection: NewsHomeProjection?
    @State private var failedImages: Set<URL> = []
    @State private var limit = 100

    private struct Input: Equatable, Sendable {
        let articles: [ArticleContent]
        let feeds: [Feed]
        let section: NewsHomeSection
        let editionDate: Date
        let limit: Int
        let isReading: Bool
    }

    private var input: Input {
        Input(articles: store.visibleArticles.map(ArticleContent.init), feeds: store.feeds,
              section: section, editionDate: editionDate, limit: limit, isReading: isReading)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    header.id("news-top")
                    categoryBar
                    refreshStatus
                    content
                }
                .frame(maxWidth: 820, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.top, 12)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity)
            }
            .background(Color("ListBackground").ignoresSafeArea())
            .refreshable {
                await store.refreshAllAndWait()
                readSnapshot = Dictionary(store.visibleArticles.map { ($0.id, $0.isRead) }, uniquingKeysWith: { a, _ in a })
                editionDate = .now
            }
            .onChange(of: tabChrome.scrollToTopSignal) { _, _ in
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
                    proxy.scrollTo("news-top", anchor: .top)
                }
            }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, y in
                tabChrome.noteScroll(offsetY: y)
            }
            .onScrollPhaseChange { old, new in
                if new == .idle || old == .idle { tabChrome.releaseExpandHold() }
            }
            .onPreferenceChange(FirstRowFrameKey.self) { frame in
                if tour.firstRowFrame != frame { tour.firstRowFrame = frame }
            }
        }
        .task(id: input) {
            let value = input
            guard !value.isReading else { return }
            for article in store.visibleArticles where readSnapshot[article.id] == nil {
                readSnapshot[article.id] = article.isRead
            }
            let reads = readSnapshot
            let result = await Task.detached(priority: .userInitiated) {
                NewsHomeProjection(articles: value.articles.map { $0.makeArticle() }, feeds: value.feeds,
                                   section: value.section, readState: reads, now: value.editionDate, limit: value.limit)
            }.value
            guard !Task.isCancelled else { return }
            projection = result
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(greeting).font(.subheadline).foregroundStyle(.secondary)
            Text(editionDate, format: .dateTime.month(.wide).day())
                .font(.system(.largeTitle, design: .serif, weight: .bold))
                .accessibilityAddTraits(.isHeader)
        }
    }

    private var greeting: LocalizedStringKey {
        switch Calendar.current.component(.hour, from: editionDate) {
        case 5..<12: "Good morning"
        case 12..<18: "Good afternoon"
        default: "Good evening"
        }
    }

    private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 22) {
                ForEach(NewsHomeSection.navigation, id: \.self) { item in
                    Button {
                        section = item
                        limit = 100
                    } label: {
                        VStack(spacing: 10) {
                            Text(item.title).font(.subheadline.weight(section == item ? .semibold : .regular))
                                .fixedSize()
                            Rectangle().fill(section == item ? Color.accentColor : .clear).frame(height: 2)
                        }
                        .padding(.top, 10)
                        .padding(.bottom, 2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(section == item ? [.isSelected] : [])
                }
            }
        }
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder private var refreshStatus: some View {
        if let outcome = store.newsRefreshOutcome, outcome.failed > 0 {
            Label(outcome.succeeded > 0
                  ? "Some feeds couldn’t refresh. Showing available stories."
                  : "Couldn’t refresh feeds. Showing saved stories.", systemImage: "wifi.exclamationmark")
                .font(.caption).foregroundStyle(.secondary)
        }
        if let updated = store.lastRefreshedAt {
            TimelineView(.periodic(from: .now, by: 60)) { timeline in
                if timeline.date.timeIntervalSince(updated) < 60 {
                    Text("Updated just now").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Updated \(updated, style: .relative) ago").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        if store.visibleArticles.isEmpty && (store.isRefreshing || store.bootstrapPhase != nil) {
            NewsHomeSkeleton()
        } else if store.feeds.isEmpty {
            ContentUnavailableView {
                Label("Your front page starts here", systemImage: "newspaper")
            } description: {
                Text("Add a few feeds to bring your publishers together.")
            } actions: {
                Button("Explore feeds", action: onExplore)
            }
        } else if let projection {
            if let hero = projection.hero {
                storyButton(hero) { HeroStoryCard(story: hero, failedImages: $failedImages) }
                    .background {
                        if tour.listHintActive {
                            GeometryReader { geometry in
                                Color.clear.preference(key: FirstRowFrameKey.self, value: geometry.frame(in: .global))
                            }
                        }
                    }
                ForEach(projection.primaryStories) { story in
                    Divider()
                    storyButton(story) { HorizontalStoryCard(story: story, failedImages: $failedImages) }
                }
                ForEach(Array(projection.secondaryStories.enumerated()), id: \.element.id) { index, story in
                    Divider()
                    storyButton(story) {
                        if index % 3 == 2 {
                            HorizontalStoryCard(story: story, failedImages: $failedImages)
                        } else {
                            CompactStoryCard(story: story)
                        }
                    }
                }
                if projection.totalCount > projection.stories.count {
                    Button("More stories") { limit += 100 }
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                }
            } else {
                ContentUnavailableView {
                    Label(section == .forYou ? "No stories yet" : "No stories in this section", systemImage: "text.page")
                } description: {
                    Text("Pull to refresh, or explore another section.")
                } actions: {
                    if section != .forYou { Button("See all sections") { section = .forYou } }
                }
            }
        } else {
            NewsHomeSkeleton()
        }
    }

    private func storyButton<Content: View>(_ story: NewsHomeStory, @ViewBuilder content: () -> Content) -> some View {
        let live = store.article(withID: story.id) ?? story.article
        return Button { onOpen(live) } label: {
            content().frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(story.article.title), \(story.publisher.name), \(story.classification.category.title), \(story.article.publishedAt.formatted(.relative(presentation: .named)))")
        .accessibilityValue(live.isRead ? Text("Read") : Text("Unread"))
        .accessibilityHint("Open article")
        .contextMenu {
            Button(live.isRead ? "Mark as Unread" : "Mark as Read") {
                store.setRead(articleID: story.id, isRead: !live.isRead)
            }
            Button(live.isStarred ? "Remove from Saved" : "Save Article", systemImage: live.isStarred ? "star.slash" : "star") {
                store.toggleStarred(articleID: story.id)
            }
            Menu("News section for this feed") {
                Button("Automatic") { store.setNewsCategoryOverride(story.article.feedID, category: nil) }
                ForEach(NewsCategory.allCases, id: \.self) { category in
                    Button(category.title) { store.setNewsCategoryOverride(story.article.feedID, category: category) }
                }
            }
            ShareLink(item: story.article.url)
        }
    }
}

private struct HeroStoryCard: View {
    let story: NewsHomeStory
    @Binding var failedImages: Set<URL>
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize = 32.0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            NewsStoryImage(url: story.imageURL, ratio: 16 / 9, corner: 16, failedImages: $failedImages)
            Text(story.article.title).font(.system(size: titleSize, weight: .bold, design: .serif))
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle = story.article.subtitle, !subtitle.isEmpty {
                Text(subtitle).font(.title3).foregroundStyle(.secondary)
            } else if !story.article.summary.isEmpty {
                Text(story.article.summary).font(.body).foregroundStyle(.secondary).lineLimit(3)
            }
            NewsStoryMetadata(story: story, includeCategory: true)
        }
    }
}

private struct HorizontalStoryCard: View {
    let story: NewsHomeStory
    @Binding var failedImages: Set<URL>
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 9) {
                Text(story.article.title).font(.system(.title3, design: .serif, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if !story.article.summary.isEmpty {
                    Text(story.article.summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                NewsStoryMetadata(story: story, includeCategory: false)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if !typeSize.isAccessibilitySize, let url = story.imageURL, !failedImages.contains(url) {
                NewsStoryImage(url: url, ratio: 4 / 3, corner: 8, failedImages: $failedImages)
                    .frame(maxWidth: 100)
            }
        }
    }
}

private struct CompactStoryCard: View {
    let story: NewsHomeStory
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(story.article.title).font(.system(.headline, design: .serif))
                .fixedSize(horizontal: false, vertical: true)
            NewsStoryMetadata(story: story, includeCategory: false)
        }
    }
}

private struct NewsStoryMetadata: View {
    let story: NewsHomeStory
    var includeCategory: Bool
    var body: some View {
        (Text(story.publisher.name) + Text(" · ")
         + Text(includeCategory ? story.classification.category.title + " · " : "")
         + Text(story.article.publishedAt, style: .relative))
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct NewsStoryImage: View {
    let url: URL?
    let ratio: CGFloat
    let corner: CGFloat
    @Binding var failedImages: Set<URL>

    var body: some View {
        if let url, !failedImages.contains(url) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    Color.clear.aspectRatio(ratio, contentMode: .fit)
                        .overlay { image.resizable().scaledToFill() }
                        .clipShape(RoundedRectangle(cornerRadius: corner))
                        .accessibilityHidden(true)
                case .failure:
                    Color.clear.frame(height: 0).onAppear { failedImages.insert(url) }
                default:
                    // No empty image rectangle. Text is immediately readable;
                    // successful images join the layout when available.
                    Color.clear.frame(height: 0)
                }
            }
        }
    }
}

private struct NewsHomeSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            ForEach(0..<3) { index in
                VStack(alignment: .leading, spacing: 12) {
                    Text("Stories from your publishers").font(index == 0 ? .largeTitle : .title3)
                    Text("A new edition is on its way.").font(.body)
                    Text("Publisher · Section · Time").font(.caption)
                }.redacted(reason: .placeholder)
                Divider()
            }
        }.accessibilityElement(children: .ignore).accessibilityLabel("Loading stories")
    }
}

extension NewsCategory {
    var title: String {
        switch self {
        case .world: String(localized: "World")
        case .business: String(localized: "Business")
        case .technology: String(localized: "Technology")
        case .science: String(localized: "Science")
        case .culture: String(localized: "Culture")
        case .longReads: String(localized: "Long Reads")
        case .other: String(localized: "Other")
        }
    }
}

private extension NewsHomeSection {
    var title: String {
        switch self {
        case .forYou: String(localized: "For You")
        case .category(let category): category.title
        }
    }
}
