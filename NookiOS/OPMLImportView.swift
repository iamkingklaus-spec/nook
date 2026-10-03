import NookKit
import SwiftUI
import UIKit

struct OPMLImportRequest: Identifiable {
    let id = UUID()
    let feeds: [OPMLFeed]
}

/// An import preview: pick which OPML feeds to bring in before merging.
/// Feeds already subscribed are shown disabled and unchecked by default.
struct OPMLImportView: View {
    let feeds: [OPMLFeed]
    let existingKeys: Set<String>
    var onImport: ([OPMLFeed]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<OPMLFeed.ID>

    init(feeds: [OPMLFeed], existingKeys: Set<String>, onImport: @escaping ([OPMLFeed]) -> Void) {
        self.feeds = feeds
        self.existingKeys = existingKeys
        self.onImport = onImport
        _selection = State(initialValue: OPMLService.selectableIDs(feeds, existingKeys: existingKeys))
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(groupedFeeds, id: \.category) { group in
                    Section(group.category ?? String(localized: "Ungrouped")) {
                        ForEach(group.feeds) { feed in
                            row(feed).nookRows()
                        }
                    }
                }
            }
            .nookScreen()
            .navigationTitle("Import Feeds")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(allSelected ? "Deselect All" : "Select All") {
                        selection = allSelected ? [] : selectableIDs
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import \(selection.count)") {
                        onImport(feeds.filter { selection.contains($0.id) })
                        dismiss()
                    }
                    .disabled(selection.isEmpty)
                }
            }
        }
    }

    private func row(_ feed: OPMLFeed) -> some View {
        let existing = isExisting(feed)
        return Button {
            if selection.contains(feed.id) {
                selection.remove(feed.id)
            } else {
                selection.insert(feed.id)
            }
        } label: {
            HStack {
                Image(systemName: selection.contains(feed.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selection.contains(feed.id) ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(feed.title).foregroundStyle(.primary)
                    Text(feed.feedURL.absoluteString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if existing {
                    Text("Added").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .disabled(existing)
    }

    private func isExisting(_ feed: OPMLFeed) -> Bool {
        existingKeys.contains(feed.feedURL.feedIdentityKey)
            || (feed.siteURL.map { existingKeys.contains($0.feedIdentityKey) } ?? false)
    }

    private var selectableIDs: Set<OPMLFeed.ID> { OPMLService.selectableIDs(feeds, existingKeys: existingKeys) }
    private var allSelected: Bool { selection == selectableIDs }

    private var groupedFeeds: [(category: String?, feeds: [OPMLFeed])] {
        var order: [String?] = []
        var map: [String?: [OPMLFeed]] = [:]
        for feed in feeds {
            if map[feed.category] == nil { order.append(feed.category) }
            map[feed.category, default: []].append(feed)
        }
        return order.map { ($0, map[$0] ?? []) }
    }
}

/// The OPML session has fixed file types for its entire lifetime. It never
/// reuses a folder-mode picker. Preview begins only after picker dismissal.
struct OPMLImportPickerModifier: ViewModifier {
    let store: ReaderStore
    @Binding var isPresented: Bool
    @State private var pendingURL: URL?
    @State private var preview: OPMLImportRequest?

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented, onDismiss: {
                guard let url = pendingURL else { return }
                pendingURL = nil
                // parseOPML owns startAccessing/defer stopAccessing for the
                // entire synchronous read. Errors and preview both appear only
                // after Files has dismissed, avoiding competing presentations.
                let feeds = store.parseOPML(at: url)
                if !feeds.isEmpty { preview = OPMLImportRequest(feeds: feeds) }
                else if store.errorMessage == nil {
                    store.errorMessage = String(localized: "No feeds found in the OPML file.")
                }
            }) {
                OPMLDocumentPicker { url in
                    pendingURL = url
                    isPresented = false
                }
            }
            .sheet(item: $preview) { request in
                OPMLImportView(feeds: request.feeds,
                    existingKeys: Set(store.feeds.flatMap { [$0.feedURL.feedIdentityKey, $0.siteURL.feedIdentityKey] })) {
                    store.importFeeds($0)
                }
            }
    }
}

private struct OPMLDocumentPicker: UIViewControllerRepresentable {
    let completion: (URL?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: OPMLImportTypes.allowed, asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    @MainActor final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let completion: (URL?) -> Void
        private var completed = false
        init(completion: @escaping (URL?) -> Void) { self.completion = completion }
        private func finish(_ url: URL?) {
            guard !completed else { return }
            completed = true
            completion(url)
        }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { finish(urls.first) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish(nil) }
    }
}
