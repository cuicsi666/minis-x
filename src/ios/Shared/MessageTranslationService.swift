//
//  MessageTranslationService.swift
//  MinisApp
//
//  Minis_X — 消息翻译（闭包注入式：由集成层提供"把文本交给模型翻译"的能力）。
//

import Foundation

final class MessageTranslationService: ObservableObject {

    nonisolated(unsafe) static let shared = MessageTranslationService()

    /// 译文缓存：messageId -> 译文（内存态，会话内复用）。
    @Published private(set) var results: [String: String] = [:]
    /// 正在翻译的消息 id。
    @Published private(set) var inFlight: Set<String> = []

    /// 由集成层注入的翻译实现：输入原文、返回译文。
    /// 必须是纯函数（同一段文本翻译结果一致）。
    var translator: ((String) async throws -> String)?

    private init() {}

    func cachedTranslation(for messageId: String) -> String? {
        results[messageId]
    }

    /// 翻译一条消息；并发防重：同一 id 已在翻译中则直接返回。
    func translate(messageId: String, text: String) async {
        guard !inFlight.contains(messageId) else { return }
        guard let translator else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        inFlight.insert(messageId)
        defer { inFlight.remove(messageId) }

        do {
            let out = try await translator(text)
            guard !out.isEmpty else { return }
            results[messageId] = out
        } catch {
            // 失败静默（下次点击重试）
        }
    }

    func clearCache() {
        results.removeAll()
    }
}


// MARK: - Cross-view requests (message menu -> chat host)
extension Notification.Name {
    /// 消息菜单点「翻译」（userInfo: id / text）
    static let minisXTranslateRequest = Notification.Name("MinisX.translateRequest")
    /// 消息菜单点「分享长图」（userInfo: text / title）
    static let minisXShareImageRequest = Notification.Name("MinisX.shareImageRequest")
}
