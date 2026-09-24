import SwiftUI

/// A completeness warning leaves the readable body and recovery actions visible.
public struct ReaderQualityNotice: View {
    private let quality: ReaderContentQuality?
    private let url: URL
    private let onRetry: () -> Void
    private let onParser: (ReaderParserEngine) -> Void

    public init(quality: ReaderContentQuality?, url: URL,
                onRetry: @escaping () -> Void, onParser: @escaping (ReaderParserEngine) -> Void) {
        self.quality = quality
        self.url = url
        self.onRetry = onRetry
        self.onParser = onParser
    }

    public var body: some View {
        if let notice = quality?.notice {
            VStack(alignment: .leading, spacing: 8) {
                Text(notice).font(.callout).foregroundStyle(.secondary)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { actions }
                    VStack(alignment: .leading, spacing: 8) { actions }
                }
                .font(.caption)
                .buttonStyle(.plain)
                .tint(.accentColor)
            }
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder private var actions: some View {
        Button("Retry", action: onRetry)
        Button("Read with Legibility") { onParser(.legibility) }
        Button("Read with Readability") { onParser(.readability) }
        Link("Open Original", destination: url)
    }
}
