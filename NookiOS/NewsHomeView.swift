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
    @State private var categoryScrollPosition: NewsHomeSection?

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
                LazyVStack(alignment: .leading, spacing: 16) {
                    header.id("news-top")
                    categoryBar
                    refreshStatus
                    content
                }
                .frame(maxWidth: 820, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.top, 4)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
            .background(NewsPalette.backgroundPrimary.ignoresSafeArea())
            .foregroundStyle(NewsPalette.textPrimary)
            .tint(NewsPalette.accentPrimary)
            .accessibilityIdentifier("news.home.scroll")
            .refreshable {
                await store.refreshAllAndWait()
                readSnapshot = Dictionary(store.visibleArticles.map { ($0.id, $0.isRead) }, uniquingKeysWith: { a, _ in a })
                editionDate = .now
            }
            .onChange(of: section) { _, _ in proxy.scrollTo("news-top", anchor: .top) }
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
        VStack(alignment: .leading, spacing: 2) {
            Text(greeting).newsFont(.greeting).foregroundStyle(NewsPalette.textSecondary)
            Text(editionDate, format: .dateTime.month(.wide).day())
                .newsFont(.date)
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
            HStack(spacing: 20) {
                ForEach(NewsHomeSection.navigation, id: \.self) { item in
                    Button {
                        section = item
                        limit = 100
                    } label: {
                        VStack(spacing: 7) {
                            Text(item.title).newsFont(.category)
                                .fontWeight(section == item ? .semibold : .regular)
                                .foregroundStyle(section == item ? NewsPalette.accentPrimary : NewsPalette.textPrimary)
                                .fixedSize()
                            Rectangle().fill(section == item ? NewsPalette.accentPrimary : .clear)
                                .frame(width: 32, height: 2).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.top, 7)
                        .padding(.bottom, 2)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .id(item)
                    .accessibilityIdentifier("news.section." + item.identifier)
                    .accessibilityAddTraits(section == item ? [.isSelected] : [])
                }
            }
            .scrollTargetLayout()
            .padding(.trailing, 24)
        }
        .scrollPosition(id: $categoryScrollPosition, anchor: .center)
        .onChange(of: section) { _, value in categoryScrollPosition = value }
        .accessibilityIdentifier("news.categories")
        // Fade the next item into the viewport; trailing padding keeps the last
        // item fully readable at the end. The gradient controls alpha only.
        .mask {
            HStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 18)
            }
        }
        .overlay(alignment: .bottom) { NewsRule() }
    }

    @ViewBuilder private var refreshStatus: some View {
        if let outcome = store.newsRefreshOutcome, outcome.failed > 0 {
            Label(outcome.succeeded > 0
                  ? "Some feeds couldn’t refresh. Showing available stories."
                  : "Couldn’t refresh feeds. Showing saved stories.", systemImage: "wifi.exclamationmark")
                .newsFont(.metadata).foregroundStyle(NewsPalette.accentSecondary)
        }
        if let updated = store.lastRefreshedAt {
            TimelineView(.periodic(from: .now, by: 60)) { timeline in
                if timeline.date.timeIntervalSince(updated) < 60 {
                    Text("Updated just now").newsFont(.metadata).foregroundStyle(NewsPalette.textTertiary)
                } else {
                    Text("Updated \(NewsMetadataFormat.age(updated, now: timeline.date)) ago").newsFont(.metadata).foregroundStyle(NewsPalette.textTertiary)
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
                    .accessibilityIdentifier("news.hero")
                    .background {
                        if tour.listHintActive {
                            GeometryReader { geometry in
                                Color.clear.preference(key: FirstRowFrameKey.self, value: geometry.frame(in: .global))
                            }
                        }
                    }
                ForEach(projection.primaryStories) { story in
                    NewsRule()
                    storyButton(story) { HorizontalStoryCard(story: story, failedImages: $failedImages) }
                }
                ForEach(Array(projection.secondaryStories.enumerated()), id: \.element.id) { index, story in
                    NewsRule()
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
        .accessibilityLabel("\(story.article.title), \(story.publisher.name), \(story.classification.category.title), \(NewsMetadataFormat.age(story.article.publishedAt, now: .now))")
        .accessibilityValue(live.isRead ? Text("Read") : Text("Unread"))
        .accessibilityHint("Open article")
        .accessibilityIdentifier(story.id == projection?.stories.last?.id ? "news.lastStory" : "news.story." + story.id)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            NewsStoryImage(url: story.imageURL, ratio: 16 / 9, corner: 13, failedImages: $failedImages)
            Text(story.article.title).newsFont(.hero).lineSpacing(1)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle = story.article.subtitle, !subtitle.isEmpty {
                Text(subtitle).newsFont(.heroSummary).lineSpacing(3).foregroundStyle(NewsPalette.textSecondary).lineLimit(3)
            } else if !story.article.summary.isEmpty {
                Text(story.article.summary).newsFont(.heroSummary).lineSpacing(3)
                    .foregroundStyle(NewsPalette.textSecondary).lineLimit(3)
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
                Text(story.article.title).newsFont(.horizontalTitle).lineSpacing(1)
                    .fixedSize(horizontal: false, vertical: true)
                if !story.article.summary.isEmpty {
                    Text(story.article.summary).newsFont(.summary).lineSpacing(3)
                        .foregroundStyle(NewsPalette.textSecondary).lineLimit(2)
                }
                NewsStoryMetadata(story: story, includeCategory: false)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if !typeSize.isAccessibilitySize, let url = story.imageURL, !failedImages.contains(url) {
                NewsStoryImage(url: url, ratio: 4 / 3, corner: 9, failedImages: $failedImages)
                    .frame(maxWidth: 100)
            }
        }
    }
}

private struct CompactStoryCard: View {
    let story: NewsHomeStory
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(story.article.title).newsFont(.compactTitle).lineSpacing(1)
                .fixedSize(horizontal: false, vertical: true)
            NewsStoryMetadata(story: story, includeCategory: false)
        }
    }
}

private struct NewsStoryMetadata: View {
    let story: NewsHomeStory
    var includeCategory: Bool
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            (Text(story.publisher.name).foregroundColor(NewsPalette.textSecondary) + Text(" · ")
             + Text(includeCategory ? story.classification.category.title + " · " : "")
             + Text(NewsMetadataFormat.age(story.article.publishedAt, now: timeline.date)))
                .newsFont(.metadata).foregroundStyle(NewsPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
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
                    Text("Stories from your publishers").newsFont(index == 0 ? .hero : .horizontalTitle)
                    Text("A new edition is on its way.").newsFont(.summary)
                    Text("Publisher · Section · Time").newsFont(.metadata)
                }.redacted(reason: .placeholder)
                NewsRule()
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
    var identifier: String {
        switch self {
        case .forYou: "forYou"
        case .category(let category): category.rawValue
        }
    }

    var title: String {
        switch self {
        case .forYou: String(localized: "For You")
        case .category(let category): category.title
        }
    }
}
