import SwiftUI

public struct BlockReaderControls: View {
    @Bindable private var controller: BlockReaderTranslationController
    private let onSelectMode: () -> Void

    public init(controller: BlockReaderTranslationController, onSelectMode: @escaping () -> Void) {
        self.controller = controller
        self.onSelectMode = onSelectMode
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("阅读语言", selection: Binding(get: { controller.mode }, set: {
                onSelectMode()
                controller.mode = $0
            })) {
                ForEach(BlockReaderMode.allCases) { mode in Text(mode.label).tag(mode) }
            }
            .pickerStyle(.segmented)
            if controller.mode != .english {
                if controller.isLoading {
                    ProgressView("正在准备正文…").font(.caption)
                } else if !controller.isComplete {
                    HStack {
                        Button(controller.translatedCount == 0 ? "翻译为简体中文" : "继续翻译") {
                            Task { await controller.translate() }
                        }
                        .disabled(controller.isTranslating || !controller.isPrepared)
                        if controller.isTranslating { ProgressView().controlSize(.small) }
                        Spacer()
                        Text("\(controller.translatedCount)/\(controller.totalCount)").monospacedDigit()
                    }
                    .font(.subheadline)
                    Text("Gemini · 仅点击翻译时发送正文；未完成的段落显示原文。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let message = controller.message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

public struct BlockReaderContentView: View {
    private let controller: BlockReaderTranslationController
    private let typography: ReaderTypography
    private let learningArticle: LearningArticleContext?

    public init(controller: BlockReaderTranslationController, typography: ReaderTypography,
                learningArticle: LearningArticleContext? = nil) {
        self.controller = controller
        self.typography = typography
        self.learningArticle = learningArticle
    }

    public var body: some View {
        if let document = controller.prepared {
            BlockReaderNodesView(nodes: document.nodes, translations: controller.translatedHTML,
                                 mode: controller.mode, typography: typography,
                                 document: document.document, learningArticle: learningArticle)
        }
    }
}

private struct BlockReaderNodesView: View {
    let nodes: [BlockReaderNode]
    let translations: [String: String]
    let mode: BlockReaderMode
    let typography: ReaderTypography
    let document: ArticleDocument
    let learningArticle: LearningArticleContext?

    var body: some View {
        VStack(alignment: .leading, spacing: 19) {
            ForEach(Array(nodes.enumerated()), id: \.offset) { _, node in
                nodeView(node)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Type erasure is confined to recursive containers, not the text importer.
    private func children(_ nodes: [BlockReaderNode]) -> some View {
        BlockReaderNodesView(nodes: nodes, translations: translations, mode: mode, typography: typography,
                             document: document, learningArticle: learningArticle)
    }

    @ViewBuilder private func nodeView(_ node: BlockReaderNode) -> some View {
        switch node {
        case .text(let id, let html, let heading):
            VStack(alignment: .leading, spacing: 7) {
                if mode != .chinese || translations[id] == nil {
                    sourceText(id: id, html: html, heading: heading)
                }
                if mode != .english, let translated = translations[id] {
                    HTMLContentText(html: translated, selectable: false,
                                    baseSize: heading.map { chineseTypography.headingSize($0) },
                                    bold: heading != nil, typography: chineseTypography, secondaryText: true)
                        .foregroundStyle(.secondary)
                }
            }
        case .quote(let nodes):
            HStack(alignment: .top, spacing: 12) {
                Rectangle().fill(.tertiary).frame(width: 3)
                AnyView(children(nodes))
            }.fixedSize(horizontal: false, vertical: true)
        case .list(let ordered, let items):
            VStack(alignment: .leading, spacing: 19) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 8) {
                        Text(ordered ? "\(index + 1)." : "•")
                            .font(.system(size: typography.bodySize))
                            .frame(minWidth: 18, alignment: .trailing)
                        AnyView(children(item))
                    }
                }
            }
        case .unchanged(let block):
            HTMLBlockList(blocks: [block], selectable: false, typography: typography)
        }
    }

    private var chineseTypography: ReaderTypography {
        var value = typography
        value.bodySize = max(10, value.bodySize - 2)
        return value
    }

    @ViewBuilder private func sourceText(id: String, html: String, heading: Int?) -> some View {
        #if canImport(UIKit)
        if let learningArticle {
            LearningSourceText(html: html, blockID: id, document: document, article: learningArticle,
                               typography: typography, heading: heading)
                .id(document.documentHash + id)
        } else {
            originalSource(html: html, heading: heading)
        }
        #else
        originalSource(html: html, heading: heading)
        #endif
    }

    private func originalSource(html: String, heading: Int?) -> some View {
        HTMLContentText(html: html, selectable: false,
                        baseSize: heading.map { typography.headingSize($0) },
                        bold: heading != nil, typography: typography)
    }
}
