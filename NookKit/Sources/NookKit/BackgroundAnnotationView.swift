import SwiftUI

struct BackgroundRequest: Identifiable {
    let id = UUID()
    let input: BackgroundInput
}

struct BackgroundAnnotationSheet: View {
    let request: BackgroundRequest
    @State private var controller = BackgroundController()
    @State private var retry = 0
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(request.input.selectedText).font(NookTypography.storyTitle)
                    Text(request.input.title).font(NookTypography.caption).foregroundStyle(NookTheme.textSecondary)
                }
                if controller.loading { ProgressView("正在解释背景…") }
                if let value = controller.result {
                    Section("是什么 · 一般背景") {
                        Text(value.entity).font(NookTypography.sectionTitle)
                        Text(value.category).font(NookTypography.caption).foregroundStyle(NookTheme.textSecondary)
                        Text(value.definition)
                    }
                    Section("与本文相关") {
                        if value.relationStatus == .supported, let relation = value.articleRelation {
                            Text(relation)
                            if let quote = value.evidenceQuote { Text(quote).font(NookTypography.caption).foregroundStyle(NookTheme.textSecondary) }
                        } else { Text("当前提供的上下文不足以确认本文关系。") }
                    }
                    if !value.generalBackground.isEmpty {
                        Section("需要知道 · 一般背景") {
                            ForEach(Array(value.generalBackground.enumerated()), id: \.offset) { _, point in Text(point) }
                        }
                    }
                    if controller.cacheHit { Text("来自本地缓存").font(NookTypography.caption) }
                }
                if let message = controller.message { Text(message).foregroundStyle(NookTheme.textSecondary) }
                if !controller.loading && controller.result == nil {
                    Button("重试背景解释") { retry += 1 }.buttonStyle(NookActionStyle())
                }
                Section {} footer: {
                    Text("仅发送选中内容、当前段落、最多两个相邻片段与文章标题/来源/日期。一般背景由 AI 生成，未经外部检索验证，请核对原文。")
                }
            }
            .nookScreen().navigationTitle("背景 / Background")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .task(id: request.id.uuidString + String(retry)) { await controller.load(request.input) }
        .onDisappear { controller.cancel() }
    }
}
