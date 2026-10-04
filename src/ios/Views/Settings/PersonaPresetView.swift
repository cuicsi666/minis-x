//
//  PersonaPresetView.swift
//  MinisApp
//
//  Minis_X — AI 人设预设设置页。
//

import SwiftUI

struct PersonaPresetView: View {

    @ObservedObject private var store = PersonaPresetStore.shared
    @State private var editing: PersonaPreset?
    @State private var showNew = false

    var body: some View {
        List {
            Section {
                ForEach(store.presets) { p in
                    HStack(spacing: 12) {
                        Text(p.emoji)
                            .font(.title3)
                            .frame(width: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name)
                                .font(.subheadline.weight(.medium))
                            Text(String(p.prompt.prefix(36)) + "…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        if store.activeId == p.id {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { store.activate(id: p.id) }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { store.remove(id: p.id) } label: {
                            Label("删除", systemImage: "trash")
                        }
                        Button { editing = p } label: {
                            Label("编辑", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
                }
                .onDelete { offsets in
                    for i in offsets { store.remove(id: store.presets[i].id) }
                }
            } header: {
                Text("选中的人设将在新回合中生效")
            } footer: {
                Text("选中即启用；再次点按同一条可取消。")
            }
        }
        .navigationTitle(Text("AI 人设预设"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showNew = true } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(item: $editing) { p in
            PersonaPresetEditor(preset: p) { name, emoji, prompt in
                store.update(id: p.id, name: name, emoji: emoji, prompt: prompt)
            }
        }
        .sheet(isPresented: $showNew) {
            PersonaPresetEditor(preset: nil) { name, emoji, prompt in
                store.add(name: name, emoji: emoji, prompt: prompt)
            }
        }
    }
}

/// 人设编辑器（新建 / 编辑共用）。为避开与已有 `QuickPromptEditorTarget`
/// 同名，本类型用 `PersonaEditTarget` 且不做 Identifiable。
struct PersonaPresetEditor: View {

    let preset: PersonaPreset?
    let onSave: (String, String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var emoji: String
    @State private var prompt: String

    init(preset: PersonaPreset?, onSave: @escaping (String, String, String) -> Void) {
        self.preset = preset
        self.onSave = onSave
        _name = State(initialValue: preset?.name ?? "")
        _emoji = State(initialValue: preset?.emoji ?? "🙂")
        _prompt = State(initialValue: preset?.prompt ?? "")
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !prompt.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名称，例如：严谨程序员", text: $name)
                    TextField("图标（emoji）", text: $emoji)
                } header: { Text("名字") }

                Section {
                    TextEditor(text: $prompt)
                        .frame(minHeight: 170)
                } header: { Text("系统提示词") } footer: {
                    Text("为人设写一段简短的行为说明，会作为系统提示词随回合发送。")
                }
            }
            .navigationTitle(Text(preset == nil ? "新建人设" : "编辑人设"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(name.trimmingCharacters(in: .whitespaces),
                               emoji.isEmpty ? "🙂" : emoji,
                               prompt)
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
    }
}
