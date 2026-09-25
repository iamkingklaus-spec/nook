import SwiftUI

public struct VocabularyView: View {
    @State private var store = ReaderLearningStore.shared
    @State private var query = ""
    @State private var errorMessage: String?
    public init() {}
    public var body: some View {
        List {
            if let error = store.loadError { Text(error).foregroundStyle(.red) }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            ForEach(store.search(query)) { entry in
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.word).font(.headline)
                    if entry.lemma.lowercased() != entry.word.lowercased() { Text(entry.lemma).font(.caption).foregroundStyle(.secondary) }
                    Text(entry.meaning)
                    Text(entry.originalSentence).font(.subheadline).foregroundStyle(.secondary)
                    Link("\(entry.publisher) · \(entry.articleTitle)", destination: entry.articleURL).font(.caption)
                    Button("删除", role: .destructive) { remove(entry.id) }.font(.caption)
                }.padding(.vertical, 4)
            }
            .onDelete { indices in
                let visible = store.search(query)
                for index in indices { remove(visible[index].id) }
            }
        }
        .navigationTitle("Vocabulary / 生词本")
        .searchable(text: $query, prompt: "搜索单词、释义、原句或来源")
        .overlay {
            if store.entries.isEmpty && store.loadError == nil {
                ContentUnavailableView("还没有生词", systemImage: "character.book.closed",
                    description: Text("在 Reader 英文正文中选词，点击 Explain Word 后保存。"))
            }
        }
    }
    private func remove(_ id: String) {
        do { try store.delete(id); errorMessage = nil }
        catch { errorMessage = "删除未能保存，请重试。" }
    }
}

private struct LearningRequest: Identifiable {
    let id = UUID()
    let selection: LearningSelection
    let type: LearningExplanationType
}

private struct LearningExplanationSheet: View {
    let request: LearningRequest
    @State private var controller = ReaderLearningController()
    @State private var saved = false
    @State private var saveError: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("选中内容") {
                    Text(request.selection.selectedText).textSelection(.enabled)
                    Text(request.selection.sentence).font(.caption).foregroundStyle(.secondary)
                }
                if controller.isLoading {
                    ProgressView("正在解释…")
                    Button("取消请求") { controller.cancel() }
                }
                if let value = controller.result {
                    Section("当前语境") {
                        if let lemma = value.lemma { Text(lemma).font(.headline) }
                        Text(value.meaning)
                        if let definition = value.englishDefinition { Text(definition).foregroundStyle(.secondary) }
                    }
                    if let usage = value.usage { Section("句中用法") { Text(usage) } }
                    if let example = value.example { Section("例句") { Text(example) } }
                    if let mainClause = value.mainClause { Section("句子主干") { Text(mainClause) } }
                    rows("语法结构", value.grammar)
                    rows("短语 / Collocations", value.phrases)
                    rows("容易误解的地方", value.pitfalls)
                    if value.type == .word {
                        Button(saved ? "已保存到生词本" : "保存到生词本") {
                            do {
                                try ReaderLearningStore.shared.save(selection: request.selection, explanation: value)
                                saved = true; saveError = nil
                            } catch { saveError = "生词保存失败，请重试。" }
                        }.disabled(saved)
                    }
                    if controller.cacheHit { Text("来自本地缓存").font(.caption).foregroundStyle(.secondary) }
                }
                if let message = controller.message { Text(message).foregroundStyle(.secondary) }
                if let saveError { Text(saveError).foregroundStyle(.red) }
                if !controller.isLoading && controller.result == nil {
                    Button("Retry / 重试") { Task { await explain() } }
                }
                Section {
                    NavigationLink("Vocabulary / 生词本") { VocabularyView() }
                } footer: {
                    Text("Gemini 仅接收选中内容、所在句子、附近段落及文章标题。AI 解释可能有误，请结合原文判断。")
                }
            }
            .navigationTitle(request.type == .word ? "Explain Word" : "Explain Sentence")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        // This sheet exists only after an explicit Explain menu action.
        .task(id: request.id) { await explain() }
        .onDisappear { controller.cancel() }
    }
    private func explain() async { await controller.explain(request.selection, type: request.type) }
    @ViewBuilder private func rows(_ title: String, _ values: [String]?) -> some View {
        if let values, !values.isEmpty {
            Section(title) { ForEach(Array(values.enumerated()), id: \.offset) { _, text in Text(text) } }
        }
    }
}

#if canImport(UIKit)
import UIKit

/// A native, non-editable source leaf: preserves inline fonts/links and gives the
/// edit menu a precise UTF-16 selection range within one stable ArticleBlock.
struct LearningSourceText: View {
    let html: String
    let blockID: String
    let document: ArticleDocument
    let article: LearningArticleContext
    let typography: ReaderTypography
    let heading: Int?
    @State private var request: LearningRequest?
    @Environment(\.openURL) private var openURL
    var body: some View {
        LearningSelectableText(html: html, typography: typography, heading: heading,
            selection: { text, range in
                LearningSelection.resolve(article: article, document: document, blockID: blockID,
                                          renderedSource: text, range: range)
            }, explain: { selection, type in
                request = LearningRequest(selection: selection, type: type)
            }, openLink: { openURL($0) })
            .sheet(item: $request) { LearningExplanationSheet(request: $0) }
    }
}

private struct LearningSelectableText: UIViewRepresentable {
    let html: String
    let typography: ReaderTypography
    let heading: Int?
    let selection: (String, NSRange) -> LearningSelection?
    let explain: (LearningSelection, LearningExplanationType) -> Void
    let openLink: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false; view.isSelectable = true; view.isScrollEnabled = false
        view.backgroundColor = .clear; view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.delegate = context.coordinator
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        let size = heading.map { typography.headingSize($0) } ?? typography.bodySize
        let key = HTMLTextFlow.cacheKey(html: html, baseSize: size, bold: heading != nil, typography: typography)
        guard context.coordinator.renderKey != key else { return }
        context.coordinator.renderKey = key
        let attributed = HTMLAttributedCache.shared.value(forKey: key)
            ?? HTMLContentText.render(html, baseSize: size, bold: heading != nil, typography: typography)
        if let attributed {
            HTMLAttributedCache.shared.store(attributed, forKey: key)
            view.attributedText = NSAttributedString(attributed)
        } else {
            view.text = HTMLContentParser.decodeEntities(html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
            view.font = .systemFont(ofSize: size); view.textColor = .label
        }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(size.height))
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: LearningSelectableText
        var renderKey: String?
        init(_ parent: LearningSelectableText) { self.parent = parent }
        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange,
                      suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard let selected = parent.selection(textView.text ?? "", range) else { return nil }
            var actions: [UIMenuElement] = []
            if selected.isWord {
                actions.append(UIAction(title: "Explain Word") { [weak self] _ in self?.parent.explain(selected, .word) })
            }
            actions.append(UIAction(title: "Explain Sentence") { [weak self] _ in self?.parent.explain(selected, .sentence) })
            return UIMenu(children: actions + suggestedActions)
        }
        func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange,
                      interaction: UITextItemInteraction) -> Bool {
            parent.openLink(URL); return false
        }
    }
}
#endif
