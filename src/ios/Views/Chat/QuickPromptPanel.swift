//
//  QuickPromptPanel.swift
//  MinisApp
//
//  Minis_X feature #5 — 快捷提示词面板 (Quick Prompts panel)。
//
//  一个自包含的 SwiftUI 视图：展示 `QuickPromptStore.shared.prompts`，
//  支持点选回调、滑动删除、拖拽排序，以及内置的新建/编辑 sheet。
//
//  自包含承诺：只 import SwiftUI / Foundation，
//  不引用任何项目内部类型（AppLocalized / ChatColors / 任何 ViewModel）。
//  颜色全部走语义色（.primary / .secondary / .tertiary / Color.accentColor
//  / 系统 material），因此暗色模式自适应，无需手写颜色分支。
//
//  用法（sheet 形式）：
//      .sheet(isPresented: $showQuickPrompts) {
//          QuickPromptPanel { prompt in
//              vm.inputText += prompt.body
//          }
//      }
//

import Foundation
import SwiftUI

// MARK: - Panel

/// 快捷提示词面板。
///
/// - 点一行 → 调用 `onPick(prompt)`；若 `autoDismiss` 为 true（默认）随后关闭。
/// - 左滑 → 删除；右上角「Edit」→ 拖拽排序 / 批量删除。
/// - 右上角「+」→ 新建；每行的「编辑」滑动操作 → 修改标题与正文。
struct QuickPromptPanel: View {

    /// 点选某条模板时的回调（集成方负责把 `prompt.body` 插入输入框）。
    private let onPick: (QuickPrompt) -> Void

    /// 点选后是否自动关闭。以 sheet 方式使用时用默认值 true；
    /// 若嵌在 popover / 输入栏内联面板里，传 false 由外层决定何时收起。
    private let autoDismiss: Bool

    @ObservedObject private var store = QuickPromptStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var editorTarget: QuickPromptEditorTarget?
    @State private var showResetConfirm = false

    /// 指定设计签名：`init(onPick:)`；`autoDismiss` 为带默认值的可选参数，
    /// 因此 `QuickPromptPanel(onPick: { ... })` 这种调用形式完全成立。
    init(onPick: @escaping (QuickPrompt) -> Void, autoDismiss: Bool = true) {
        self.onPick = onPick
        self.autoDismiss = autoDismiss
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.prompts.isEmpty {
                    emptyState
                } else {
                    promptList
                }
            }
            .navigationTitle(Text("快捷提示词"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
        }
        .sheet(item: $editorTarget) { target in
            QuickPromptEditorSheet(target: target) { newTitle, newBody in
                if target.isNew {
                    store.add(title: newTitle, body: newBody)
                } else {
                    store.update(id: target.id, title: newTitle, body: newBody)
                }
            }
        }
        .confirmationDialog(
            "恢复为内置的 6 条模板？",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                store.resetToDefaults()
            } label: {
                Text("恢复默认模板")
            }
            Button(role: .cancel) {} label: {
                Text("取消")
            }
        } message: {
            Text("当前的快捷提示词会被覆盖，此操作不可撤销。")
        }
    }

    // MARK: List

    private var promptList: some View {
        List {
            Section {
                ForEach(store.prompts) { prompt in
                    Button {
                        pick(prompt)
                    } label: {
                        row(prompt)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            store.remove(id: prompt.id)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                        Button {
                            editorTarget = QuickPromptEditorTarget(prompt: prompt)
                        } label: {
                            Label("编辑", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
                }
                .onDelete { offsets in
                    store.remove(at: offsets)
                }
                .onMove { source, destination in
                    store.move(fromOffsets: source, toOffset: destination)
                }
            } header: {
                Text("点击即可插入输入框")
            } footer: {
                Text("左滑删除，点右上角「编辑」可拖拽排序。")
            }
        }
        .listStyle(.insetGrouped)
    }

    private func row(_ prompt: QuickPrompt) -> some View {
        HStack(spacing: 12) {
            Image(systemName: QuickPromptPanel.icon(for: prompt))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 30)
                .background(
                    Color.accentColor.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(prompt.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(QuickPromptPanel.preview(of: prompt.body))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Image(systemName: "arrow.up.left.square")
                .font(.system(size: 15))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "text.bubble")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("还没有快捷提示词")
                .font(.headline)
            Text("新建一条常用指令，下次一键插入输入框。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                editorTarget = QuickPromptEditorTarget()
            } label: {
                Label("新建提示词", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button {
                dismiss()
            } label: {
                Text("关闭")
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if !store.prompts.isEmpty {
                EditButton()
            }
            Button {
                editorTarget = QuickPromptEditorTarget()
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel(Text("新建提示词"))

            Menu {
                Button {
                    editorTarget = QuickPromptEditorTarget()
                } label: {
                    Label("新建提示词", systemImage: "plus")
                }
                Button {
                    showResetConfirm = true
                } label: {
                    Label("恢复默认模板", systemImage: "arrow.counterclockwise")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel(Text("更多操作"))
        }
    }

    // MARK: Actions

    private func pick(_ prompt: QuickPrompt) {
        onPick(prompt)
        if autoDismiss {
            dismiss()
        }
    }

    // MARK: Row helpers

    /// 按标题里的关键词挑一个 SF Symbol，保持「一行一个图标」的视觉节奏。
    /// 只落到系统自带的公开 symbol，缺符号不会导致编译失败。
    static func icon(for prompt: QuickPrompt) -> String {
        let title = prompt.title
        func has(_ needles: [String]) -> Bool {
            needles.contains { title.localizedCaseInsensitiveContains($0) }
        }
        if has(["总结", "要点", "摘要", "概括", "summary"]) { return "list.bullet.rectangle" }
        if has(["翻译", "translate"]) { return "character.book.closed" }
        if has(["报错", "错误", "异常", "崩溃", "排查", "error", "bug"]) { return "exclamationmark.triangle" }
        if has(["代码", "实现", "函数", "脚本", "code"]) { return "chevron.left.forwardslash.chevron.right" }
        if has(["润色", "改写", "文字", "语气"]) { return "wand.and.stars" }
        if has(["优化", "建议", "性能", "重构"]) { return "chart.line.uptrend.xyaxis" }
        return "text.bubble"
    }

    /// 正文的一行摘要：折叠所有空白、截断到 `limit` 个字符。
    static func preview(of text: String, limit: Int = 48) -> String {
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard limit > 0, collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)) + "…"
    }
}

// MARK: - Editor plumbing

/// sheet(item:) 的载荷：既表示「新建」（`isNew == true`，`id` 是新 UUID）
/// 也表示「编辑某一条」（`id` 是被编辑模板的 id）。
private struct QuickPromptEditorTarget: Identifiable {

    let id: UUID
    let isNew: Bool
    var title: String
    var body: String

    /// 编辑既有模板。
    init(prompt: QuickPrompt) {
        self.id = prompt.id
        self.isNew = false
        self.title = prompt.title
        self.body = prompt.body
    }

    /// 新建。
    init() {
        self.id = UUID()
        self.isNew = true
        self.title = ""
        self.body = ""
    }
}

/// 标题 + 正文编辑器。保存时回调 `onSave(title, body)`，由面板写回 store。
private struct QuickPromptEditorSheet: View {

    let target: QuickPromptEditorTarget
    let onSave: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    /// 注意：这里**不能**叫 `body` —— 该类型同时是 `View`，`var body: some View`
    /// 已经占用了这个名字，再声明一个 `body: String` 会直接编译失败
    /// （invalid redeclaration of 'body'）。所以编辑器自己用 `promptTitle` /
    /// `promptBody`。
    @State private var promptTitle: String
    @State private var promptBody: String

    init(target: QuickPromptEditorTarget, onSave: @escaping (String, String) -> Void) {
        self.target = target
        self.onSave = onSave
        _promptTitle = State(initialValue: target.title)
        _promptBody = State(initialValue: target.body)
    }

    /// 标题与正文都非空才允许保存（正文保留用户输入的原始换行/缩进）。
    private var canSave: Bool {
        !promptTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !promptBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(text: $promptTitle) {
                        Text("例如：总结要点")
                    }
                } header: {
                    Text("标题")
                }

                Section {
                    TextEditor(text: $promptBody)
                        .font(.body)
                        .frame(minHeight: 170)
                        .overlay(alignment: .topLeading) {
                            if promptBody.isEmpty {
                                Text("输入发送给 AI 的提示词正文…")
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 8)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                } header: {
                    Text("提示词正文")
                } footer: {
                    Text("正文会原样插入输入框，行尾的换行也会保留。")
                }
            }
            .navigationTitle(Text(verbatim: target.isNew ? "新建提示词" : "编辑提示词"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Text("取消")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        onSave(promptTitle.trimmingCharacters(in: .whitespacesAndNewlines), promptBody)
                        dismiss()
                    } label: {
                        Text("保存")
                    }
                    .disabled(!canSave)
                }
            }
        }
    }
}

// MARK: - Preview

#Preview("Quick Prompts") {
    QuickPromptPanel { prompt in
        print("[QuickPromptPanel] picked: \(prompt.title)")
    }
}
