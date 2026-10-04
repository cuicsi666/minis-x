//
//  CallModeController.swift
//  MinisApp
//
//  Minis_X — 全新「通话模式」状态机。
//
//  设计目标：像和真人打电话一样与 AI 连续对话。
//
//  循环：
//    listening（持续聆听，VAD 检测静音）
//      → 用户说完 → onSendText(文本) → thinking
//      → AI 回复完成（notifyAssistantReply）→ speaking（TTS 播报）
//      → 播报结束（监听 MessageSpeechService.isSpeaking 回落）→ listening
//      → …循环，直到 hangUp()
//
//  解耦：本类**不直接依赖** AIChatViewModel。集成层注入三个闭包：
//    onSendText           —— 把一段文本当作"用户说了一句话"发出去
//    isAIBusy             —— 当前 AI 是否仍在处理（可选）
//    latestAssistantReply —— 取最近一条 AI 回复正文（可选，兜底用）
//
//  音频：进入通话时声明 `.capture` intent（麦克风），退出时释放；播报走
//  MessageSpeechService（其内部不抢 session，由调用方声明 intent）。
//

import AVFoundation
import Combine
import Foundation
import SwiftUI

/// 通话模式状态。
enum CallModeState: Equatable {
    case idle        // 未通话
    case listening   // 聆听中
    case thinking    // 已发送，等待 AI
    case speaking    // AI 播报中
}

@MainActor
final class CallModeController: ObservableObject {

    static let shared = CallModeController()

    // MARK: - Published state

    @Published private(set) var state: CallModeState = .idle
    @Published private(set) var startedAt: Date?
    /// 用户当前已识别到的文本（实时字幕）。
    @Published private(set) var recognizedText: String = ""
    /// AI 最近一次回复正文（字幕）。
    @Published private(set) var replyText: String = ""
    /// 波形电平（0…1，归一化后的 28 个采样）。
    @Published private(set) var levels: [Float] = Array(repeating: 0.05, count: 28)
    /// 出错提示（例如麦克风权限）。
    @Published private(set) var errorText: String?

    var isActive: Bool { state != .idle }

    // MARK: - Injection points（由集成层设置）

    /// 把一段文本作为用户消息发送。
    var onSendText: ((String) -> Void)?
    /// AI 是否仍在处理（用于兜底判断）。
    var isAIBusy: (() -> Bool)?
    /// 取最近一条 assistant 回复正文（兜底）。
    var latestAssistantReply: (() -> String)?

    // MARK: - Internals

    private let recognizer = SpeechRecognitionManager.shared
    private var cancellables = Set<AnyCancellable>()
    private var tickTask: Task<Void, Never>?

    /// 通话前「朗读回复」的原始状态，播报结束时恢复。
    private var systemReadWasEnabled = false

    private var silenceTicks = 0
    private var hasSpoken = false
    /// 连续静音达到该 tick 数（每个 0.1s）判定"说完了"。
    private let silenceTicksToSend = 13   // ≈1.3s
    /// 电平低于该值算静音。
    private let silenceLevel: Float = 0.06

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard state == .idle else { return }
        errorText = nil
        startedAt = Date()
        recognizedText = ""
        replyText = ""
        silenceTicks = 0
        hasSpoken = false

        AudioSessionCoordinator.shared.begin(.capture)
        do {
            try recognizer.startRecording()
        } catch {
            errorText = "无法开始录音：\(error.localizedDescription)"
            AudioSessionCoordinator.shared.end(.capture)
            state = .idle
            startedAt = nil
            return
        }

        state = .listening
        observeSpeechEnd()
        startTicking()
    }

    func hangUp() {
        restoreSystemRead()
        tickTask?.cancel()
        tickTask = nil
        recognizer.stopRecording()
        MessageSpeechService.shared.stop()
        AudioSessionCoordinator.shared.end(.capture)
        cancellables.removeAll()
        state = .idle
        startedAt = nil
        recognizedText = ""
        replyText = ""
        levels = Array(repeating: 0.05, count: 28)
    }

    /// 恢复通话前的「朗读回复」开关状态。
    private func restoreSystemRead() {
        if systemReadWasEnabled {
            VoiceOutputState.shared.isEnabled = true
            systemReadWasEnabled = false
        }
    }

    // MARK: - Loop

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(nanoseconds: 100_000_000)   // 0.1s
            }
        }
    }

    private func tick() {
        guard state == .listening else { return }

        let raw = recognizer.audioLevels
        if !raw.isEmpty {
            let n = levels.count
            var out: [Float] = []
            out.reserveCapacity(n)
            let stride = max(1, raw.count / n)
            var i = 0
            while i < raw.count && out.count < n {
                out.append(min(max(raw[i], 0), 1))
                i += stride
            }
            while out.count < n { out.append(0.05) }
            levels = out
        }

        recognizedText = recognizer.recognizedText

        let peak = levels.max() ?? 0
        if peak < silenceLevel {
            if hasSpoken { silenceTicks += 1 }
        } else {
            hasSpoken = true
            silenceTicks = 0
        }

        if hasSpoken && silenceTicks >= silenceTicksToSend {
            let text = recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                send(text)
            } else {
                silenceTicks = 0
                hasSpoken = false
            }
        }
    }

    private func send(_ text: String) {
        guard state == .listening else { return }
        state = .thinking
        silenceTicks = 0
        hasSpoken = false
        recognizedText = text
        recognizer.stopRecording()
        AudioSessionCoordinator.shared.end(.capture)
        onSendText?(text)
    }

    /// 集成层在收到 AI 完整回复后调用（触发播报）。
    func notifyAssistantReply(_ text: String) {
        guard state == .thinking else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        replyText = trimmed
        guard !trimmed.isEmpty else {
            resumeListening()
            return
        }
        state = .speaking
        // [Minis_X 双重播报修复] 通话播报期间暂停基础版朗读，播完自动恢复。
        systemReadWasEnabled = VoiceOutputState.shared.isEnabled
        if VoiceOutputState.shared.isEnabled { VoiceOutputState.shared.isEnabled = false }
        MessageSpeechService.shared.speak(trimmed)
    }

    /// 用户说话打断播报。
    func interruptSpeaking() {
        guard state == .speaking else { return }
        MessageSpeechService.shared.stop()
        resumeListening()
    }

    private func resumeListening() {
        guard state != .idle else { return }
        restoreSystemRead()
        recognizedText = ""
        silenceTicks = 0
        hasSpoken = false
        AudioSessionCoordinator.shared.begin(.capture)
        try? recognizer.startRecording()
        state = .listening
    }

    private func observeSpeechEnd() {
        cancellables.removeAll()
        MessageSpeechService.shared.$isSpeaking
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] speaking in
                guard let self else { return }
                if !speaking && self.state == .speaking {
                    self.resumeListening()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Derived

    var elapsed: TimeInterval {
        guard let startedAt else { return 0 }
        return Date().timeIntervalSince(startedAt)
    }
}
