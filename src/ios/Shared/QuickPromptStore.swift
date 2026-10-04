//
//  QuickPromptStore.swift
//  MinisApp
//
//  Minis_X feature #5 — 快捷提示词 (Quick Prompts) 数据层。
//
//  ─── 设计前提 ───────────────────────────────────────────────────────────────
//  * 自包含：只依赖 Foundation / Combine，**不引用任何项目内部类型**
//    （没有 AppLocalized / AppLogger / ChatColors），因此可以独立编译，
//    也不会被上游 model / view-model 的重构打断。
//  * 纯数据层：没有 View、没有 ViewModel、没有 SQLite。任何 SwiftUI 视图用
//        @ObservedObject private var store = QuickPromptStore.shared
//    即可观察。
//  * 持久化：`UserDefaults`（key = "MinisX.quickPrompts"），JSONEncoder 编成
//    `Data` 存一条 blob。模板总量是「几十条 × 几百字节」量级，属于偏好
//    数据而不是内容数据，UserDefaults 是它该待的地方（对比：收藏夹
//    ChatFavoritesStore 里存的是整条消息正文，所以那边用文件）。
//  * 预置幂等：用独立的 "MinisX.quickPrompts.seeded" 标记保证 6 条中文模板
//    只在**首次启动**注入一次；用户手动清空/删光之后不会再被塞回来。
//

import Combine
import Foundation

// MARK: - Model

/// 一条快捷提示词模板。
///
/// `body` 是要发给 AI 的提示词正文。`QuickPrompt` 不遵循 `View` 协议，
/// 所以这个属性名不会和 SwiftUI 的 `View.body` 冲突（Codable 也照常合成，
/// 磁盘 JSON 的键就是 `"body"`）。
struct QuickPrompt: Identifiable, Codable, Hashable {

    var id: UUID
    var title: String
    var body: String

    init(id: UUID = UUID(), title: String, body: String) {
        self.id = id
        self.title = title
        self.body = body
    }

    /// 标题为空 = 不可用模板（面板里用来禁用「保存」）。
    var isBlank: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Store

/// 全局快捷提示词仓库（单例 + 可变有序数组 + UserDefaults 持久化）。
///
/// 线程约定：`prompts` 是 main-thread affine —— 每次改动都**同步**更新内存
/// 数组（所以写完立刻读不会读到旧值）并**同步**写 UserDefaults。模板数量
/// 很小，UserDefaults 的 `set(_:forKey:)` 本身是内存写 + 延迟落盘，不会阻塞
/// UI；所有调用点都是 UI 回调，本来就在主线程。
final class QuickPromptStore: ObservableObject {

    /// 共享实例。`nonisolated(unsafe)` 与本仓库其它单例 Store
    /// （ChatFavoritesStore / QuotedReplyStore）保持一致的写法：显式声明该
    /// 类型不做 actor 隔离，同时保证在 Swift 6 语言模式下声明合法。
    nonisolated(unsafe) static let shared = QuickPromptStore()

    /// UserDefaults key：模板数组（JSON Data）。
    static let persistenceKey = "MinisX.quickPrompts"

    /// UserDefaults key：是否已经做过首次预置（幂等标记）。
    static let seededFlagKey = "MinisX.quickPrompts.seeded"

    /// 全部模板，顺序即面板显示顺序（也是用户可以拖拽调整的顺序）。
    /// 所有写入都走下面的方法，方法内部会同步 `persist()`。
    @Published var prompts: [QuickPrompt]

    private let defaults: UserDefaults

    // MARK: Init

    /// - Parameter defaults: 可注入，便于测试指向独立的 suite。
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let stored = QuickPromptStore.decode(from: defaults)
        let alreadySeeded = defaults.bool(forKey: QuickPromptStore.seededFlagKey)

        if alreadySeeded {
            // 曾经预置过：磁盘上没有数据就当作「用户清空了」，绝不再注入。
            self.prompts = stored ?? []
        } else {
            // 首次启动：磁盘上真的没有数据才预置默认模板。
            self.prompts = stored ?? QuickPromptStore.defaultTemplates()
            defaults.set(true, forKey: QuickPromptStore.seededFlagKey)
            if stored == nil {
                persist()
            }
        }
    }

    // MARK: Queries

    var count: Int { prompts.count }
    var isEmpty: Bool { prompts.isEmpty }

    func prompt(withId id: UUID) -> QuickPrompt? {
        prompts.first { $0.id == id }
    }

    // MARK: Mutations — 增

    /// 用标题 + 正文新建一条，追加到末尾。
    @discardableResult
    func add(title: String, body: String) -> QuickPrompt {
        let prompt = QuickPrompt(title: title, body: body)
        prompts.append(prompt)
        persist()
        return prompt
    }

    /// 追加一条已有模板（保留其 id）。
    func add(_ prompt: QuickPrompt) {
        prompts.append(prompt)
        persist()
    }

    /// 插入到指定下标（越界自动夹到合法范围），越靠前 ≈ 越常用。
    func insert(_ prompt: QuickPrompt, at index: Int) {
        let clamped = max(0, min(prompts.count, index))
        prompts.insert(prompt, at: clamped)
        persist()
    }

    // MARK: Mutations — 改

    /// 按下标改一条。
    @discardableResult
    func update(id: UUID, title: String, body: String) -> Bool {
        guard let index = prompts.firstIndex(where: { $0.id == id }) else { return false }
        var updated = prompts[index]
        updated.title = title
        updated.body = body
        guard updated != prompts[index] else { return true } // 无变化，不白写盘
        var next = prompts
        next[index] = updated
        prompts = next // 整体替换数组，确保 @Published 一定发信号
        persist()
        return true
    }

    /// 用一条完整的 `QuickPrompt` 覆盖同 id 的那条（id 不存在则返回 false）。
    @discardableResult
    func replace(_ prompt: QuickPrompt) -> Bool {
        guard let index = prompts.firstIndex(where: { $0.id == prompt.id }) else { return false }
        guard prompts[index] != prompt else { return true }
        var next = prompts
        next[index] = prompt
        prompts = next
        persist()
        return true
    }

    // MARK: Mutations — 删

    @discardableResult
    func remove(id: UUID) -> Bool {
        guard prompts.contains(where: { $0.id == id }) else { return false }
        prompts = prompts.filter { $0.id != id }
        persist()
        return true
    }

    @discardableResult
    func remove(_ prompt: QuickPrompt) -> Bool {
        remove(id: prompt.id)
    }

    /// `List` 的 `.onDelete` 直通（滑动手势 / 编辑模式批量删除）。
    func remove(at offsets: IndexSet) {
        let targets: [UUID] = offsets.compactMap { index in
            guard prompts.indices.contains(index) else { return nil }
            return prompts[index].id
        }
        guard !targets.isEmpty else { return }
        let doomed = Set(targets)
        prompts = prompts.filter { !doomed.contains($0.id) }
        persist()
    }

    /// 清空全部（不重新预置；幂等标记保持为 true）。
    @discardableResult
    func removeAll() -> Int {
        let removed = prompts.count
        guard removed > 0 else { return 0 }
        prompts = []
        persist()
        return removed
    }

    /// `removeAll()` 的可读别名。
    @discardableResult
    func clear() -> Int { removeAll() }

    // MARK: Mutations — 排序

    /// `List` 的 `.onMove` 直通。算法与 SwiftUI 的语义一致：`destination`
    /// 是**原始数组**里的插入下标，先摘除再按下标修正插入位置。
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let indices = source.sorted()
        guard !indices.isEmpty else { return }
        var next = prompts
        let moving: [QuickPrompt] = indices.compactMap { index in
            guard next.indices.contains(index) else { return nil }
            return next[index]
        }
        guard !moving.isEmpty else { return }
        for index in indices.reversed() where next.indices.contains(index) {
            next.remove(at: index)
        }
        // 目的地之前被摘掉的元素个数 = 需要左移的偏移量。
        let removedBefore = indices.filter { $0 < destination }.count
        let insertAt = max(0, min(next.count, destination - removedBefore))
        next.insert(contentsOf: moving, at: insertAt)
        prompts = next
        persist()
    }

    /// 直接的下标对下标移动（上/下移一个位置用）。
    @discardableResult
    func move(from: Int, to: Int) -> Bool {
        guard from != to,
              prompts.indices.contains(from),
              prompts.indices.contains(to) else { return false }
        var next = prompts
        let item = next.remove(at: from)
        next.insert(item, at: to)
        prompts = next
        persist()
        return true
    }

    /// 上移一位（已在顶部返回 false）。
    @discardableResult
    func moveUp(id: UUID) -> Bool {
        guard let index = prompts.firstIndex(where: { $0.id == id }), index > 0 else { return false }
        return move(from: index, to: index - 1)
    }

    /// 下移一位（已在底部返回 false）。
    @discardableResult
    func moveDown(id: UUID) -> Bool {
        guard let index = prompts.firstIndex(where: { $0.id == id }),
              index < prompts.count - 1 else { return false }
        return move(from: index, to: index + 1)
    }

    // MARK: Reset / Reload

    /// 恢复 6 条内置中文模板（覆盖当前列表）。幂等标记保持 true —— 之后用户
    /// 再清空，也不会在下次启动时自动长回来。
    func resetToDefaults() {
        prompts = QuickPromptStore.defaultTemplates()
        defaults.set(true, forKey: QuickPromptStore.seededFlagKey)
        persist()
    }

    /// 丢弃内存状态，从 UserDefaults 重新读（诊断 / 测试用）。
    func reload() {
        prompts = QuickPromptStore.decode(from: defaults) ?? []
    }

    // MARK: Persistence

    /// 把当前 `prompts` 编码写入 UserDefaults。所有增删改排序内部都会调用；
    /// 对外公开只是为了让集成方在批量操作后能手动收口（一般不需要）。
    func persist() {
        do {
            let data = try QuickPromptStore.makeEncoder().encode(prompts)
            defaults.set(data, forKey: QuickPromptStore.persistenceKey)
        } catch {
            // 编码失败不能影响 UI（模板都是 String，实践中不会失败）。
            print("[QuickPromptStore] encode failed: \(error.localizedDescription)")
        }
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static func decode(from defaults: UserDefaults) -> [QuickPrompt]? {
        guard let data = defaults.data(forKey: persistenceKey) else { return nil }
        do {
            return try JSONDecoder().decode([QuickPrompt].self, from: data)
        } catch {
            print("[QuickPromptStore] decode failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: Default templates

    /// 首次启动预置的 6 条中文模板。正文末尾统一带换行，方便用户点选后
    /// 直接在光标处补自己的内容。
    static func defaultTemplates() -> [QuickPrompt] {
        [
            QuickPrompt(
                title: "总结要点",
                body: """
                请阅读下面的内容，提炼核心要点，用简洁的条目列出（最多 7 条），并在最后用一句话给出总体结论。

                """
            ),
            QuickPrompt(
                title: "翻译成中文",
                body: """
                请把下面的内容翻译成地道、流畅的简体中文，保留专业术语与原文格式（代码、专有名词不翻译）：

                """
            ),
            QuickPrompt(
                title: "解释这段报错",
                body: """
                请解释下面这段报错信息的含义，列出常见原因，并给出按优先级排序的排查与修复步骤：

                """
            ),
            QuickPrompt(
                title: "写代码实现",
                body: """
                请用合适的语言实现下面的需求，给出完整可运行的代码，并简要说明关键实现思路和边界情况：

                """
            ),
            QuickPrompt(
                title: "润色文字",
                body: """
                请润色下面这段文字，使其更通顺、准确、专业，保持原意和原有语气，不要添加新信息：

                """
            ),
            QuickPrompt(
                title: "列出优化建议",
                body: """
                请针对下面的内容列出可执行的优化建议，按优先级从高到低排序，每条建议说明理由和预期收益：

                """
            )
        ]
    }
}
