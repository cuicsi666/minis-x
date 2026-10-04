//
//  PersonaPresetStore.swift
//  MinisApp
//
//  Minis_X — AI 人设预设（多套系统提示词一键切换）。
//

import Combine
import Foundation

/// 一套命名的人设（系统提示词）。
struct PersonaPreset: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var emoji: String
    var prompt: String

    init(id: UUID = UUID(), name: String, emoji: String, prompt: String) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.prompt = prompt
    }
}

/// 人设预设库（UserDefaults JSON 持久化，主线程亲和）。
final class PersonaPresetStore: ObservableObject {

    nonisolated(unsafe) static let shared = PersonaPresetStore()

    static let persistenceKey = "MinisX.persona.presets"
    static let activeKey = "MinisX.persona.activeId"

    @Published private(set) var presets: [PersonaPreset] = []
    @Published private(set) var activeId: UUID?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.persistenceKey),
           let list = try? JSONDecoder().decode([PersonaPreset].self, from: data) {
            presets = list
        } else {
            presets = PersonaPresetStore.builtinPresets()
            if let data = try? JSONEncoder().encode(presets) {
                defaults.set(data, forKey: Self.persistenceKey)
            }
        }
        if let raw = defaults.string(forKey: Self.activeKey), let id = UUID(uuidString: raw) {
            activeId = id
        }
    }

    // MARK: - Queries

    var activePreset: PersonaPreset? {
        presets.first { $0.id == activeId }
    }

    // MARK: - Mutations

    @discardableResult
    func add(name: String, emoji: String, prompt: String) -> PersonaPreset {
        let p = PersonaPreset(name: name, emoji: emoji, prompt: prompt)
        presets.append(p)
        persist()
        return p
    }

    @discardableResult
    func update(id: UUID, name: String, emoji: String, prompt: String) -> Bool {
        guard let i = presets.firstIndex(where: { $0.id == id }) else { return false }
        presets[i].name = name
        presets[i].emoji = emoji
        presets[i].prompt = prompt
        persist()
        return true
    }

    @discardableResult
    func remove(id: UUID) -> Bool {
        guard presets.contains(where: { $0.id == id }) else { return false }
        presets.removeAll { $0.id == id }
        if activeId == id { activeId = nil }
        persist()
        return true
    }

    func activate(id: UUID) {
        activeId = (activeId == id) ? nil : id
        defaults.set(activeId?.uuidString ?? "", forKey: Self.activeKey)
    }

    func deactivate() {
        activeId = nil
        defaults.set("", forKey: Self.activeKey)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(presets) {
            defaults.set(data, forKey: Self.persistenceKey)
        }
    }

    // MARK: - Built-ins

    static func builtinPresets() -> [PersonaPreset] {
        [
            PersonaPreset(
                name: "通用助手",
                emoji: "🙂",
                prompt: "你是 Minis 的通用智能助手。用简体中文、简洁清晰地回答问题；不确定时明确说明，不编造。"
            ),
            PersonaPreset(
                name: "严谨程序员",
                emoji: "👨‍💻",
                prompt: "你是资深工程师。回答编程问题时给出可直接运行的代码，说明关键假设、边界情况与可能的坑；优先选择项目中已有的依赖。"
            ),
            PersonaPreset(
                name: "温柔陪聊",
                emoji: "🌸",
                prompt: "你是温柔有耐心的陪伴者。语气自然、口语化、多一点共情；回答简短，不居高临下。"
            ),
            PersonaPreset(
                name: "专业翻译",
                emoji: "🌐",
                prompt: "你是专业译者。翻译时保持术语准确、语句通顺、风格一致；代码与专有名词不翻译，并简要说明用词取舍。"
            )
        ]
    }
}
