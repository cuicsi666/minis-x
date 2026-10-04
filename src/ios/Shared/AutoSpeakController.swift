//
//  AutoSpeakController.swift
//  MinisApp
//
//  Minis_X feature — AI 回复自动播报 (auto-speak a finished assistant reply).
//
//  A tiny, UI-free coordinator that answers exactly one question: "a turn just
//  finished — should the reply be read aloud, and if so, once?" It deliberately
//  owns NO view, NO AVFoundation object and NO chat model: it stores one
//  preference (persisted in UserDefaults), remembers the last reply it spoke,
//  and forwards to the existing on-device TTS engine
//  (`MessageSpeechService.shared`). The chat surface decides WHEN to call it;
//  this type only decides WHETHER and de-duplicates.
//
//  ─── Why a controller and not a call straight to MessageSpeechService ───────
//  * The enable/disable preference and the "already spoken this reply" cursor
//    must outlive a single view render, so they cannot live in @State.
//  * Keeping the policy here means the integration site in the chat view stays
//    a one-line observer, and it stays unit-testable without any UI.
//
//  ─── Threading ─────────────────────────────────────────────────────────────
//  Main-thread affine by contract: the integration site is a SwiftUI `.onChange`
//  observer, so every call already arrives on the main thread. State is mutated
//  directly (no trampoline) to keep the type trivial; `MessageSpeechService`
//  itself is safe to call from any thread, so a stray off-main call cannot
//  corrupt playback — it would only race this object's two cursors.
//
//  ─── iOS 16 note for the caller ────────────────────────────────────────────
//  Attach the observer with the SINGLE-parameter form — iOS 16 rejects the
//  two-parameter `onChange(of:initial:_:)` introduced in iOS 17:
//
//      .onChange(of: vm.isProcessing) { processing in
//          guard !processing else { return }
//          guard let last = vm.messages.last, last.role == .assistant else { return }
//          AutoSpeakController.shared.handleAssistantReplyFinished(
//              messageId: last.id.uuidString,
//              text: last.blocks.map(\.content).joined(separator: "\n\n")
//          )
//      }
//

import Combine
import Foundation

/// Coordinates "read the finished reply aloud" against a persisted preference.
///
/// Public surface (observed as `@ObservedObject private var autoSpeak = AutoSpeakController.shared`):
///
///     AutoSpeakController.shared.handleAssistantReplyFinished(messageId:text:)
///     AutoSpeakController.shared.toggle()   // -> new isEnabled
///     AutoSpeakController.shared.stop()
final class AutoSpeakController: ObservableObject {

    // MARK: - Shared instance

    /// App-wide coordinator. `nonisolated(unsafe)` mirrors the rest of `Shared/`
    /// (see `ChatFavoritesStore.shared` / `MessageSpeechService.shared`): the
    /// instance is intentionally not actor-isolated — its mutable state is
    /// main-thread affine by the caller contract documented above.
    nonisolated(unsafe) static let shared = AutoSpeakController()

    // MARK: - Persistence

    /// UserDefaults key for the on/off preference. Namespaced with the same
    /// `"MinisX."` prefix used by the other preference keys in this target.
    static let defaultsKey = "MinisX.autoSpeakOnReply"

    // MARK: - Published state

    /// Master switch. Defaults to `false` (opt-in — auto-speaking every reply
    /// uninvited is startling, so it is never on for a fresh install unless the
    /// user asked for it). Writing it persists immediately and, when turned
    /// OFF, cancels any reply currently being read.
    @Published var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            defaults.set(isEnabled, forKey: Self.defaultsKey)
            if !isEnabled { speech.stop() }
        }
    }

    /// `id` of the most recent reply handed to the engine. The de-dup cursor:
    /// it makes `handleAssistantReplyFinished` idempotent per message, so a
    /// re-fired `isProcessing` edge (retry, view re-appearance, sub-agent
    /// callback) can never read the same reply twice.
    @Published var lastSpokenMessageId: String?

    // MARK: - Collaborators

    private let defaults: UserDefaults
    private let speech: MessageSpeechService

    // MARK: - Init

    /// Injectable for tests; the app always uses `.shared`.
    init(defaults: UserDefaults = .standard,
         speech: MessageSpeechService = .shared) {
        self.defaults = defaults
        self.speech = speech
        // Read the raw object so "never toggled" (nil) and "explicitly OFF"
        // both resolve to false, while a stored `false` is respected verbatim.
        self.isEnabled = (defaults.object(forKey: Self.defaultsKey) as? Bool) ?? false
    }

    // MARK: - Public API

    /// Called once per finished assistant turn (from the chat view's
    /// `isProcessing` true→false edge). Reads `text` aloud if — and only if —
    /// auto-speak is on, the text has any non-whitespace content, and this
    /// message id has not already been spoken.
    ///
    /// - Parameters:
    ///   - messageId: stable id of the reply (`ChatMessage.id.uuidString`).
    ///   - text: the reply body to read.
    func handleAssistantReplyFinished(messageId: String, text: String) {
        guard isEnabled else { return }
        // [Minis_X 双重播报修复] 基础版「朗读回复」开关已开启时，交给那套 TTS，
        // 本模块让位，避免两套朗读同时出声。
        if VoiceOutputState.shared.isEnabled { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard messageId != lastSpokenMessageId else { return }

        lastSpokenMessageId = messageId
        speech.speak(text, messageId: messageId)
    }

    /// Stop any reply currently being read (e.g. the user toggled auto-speak
    /// off, or the chat view is going away). Does NOT clear
    /// `lastSpokenMessageId`, so the interrupted reply is not read again.
    func stop() {
        speech.stop()
    }

    /// Flip the master switch and return the new value. Convenience for a
    /// Settings toggle: `let on = AutoSpeakController.shared.toggle()`.
    @discardableResult
    func toggle() -> Bool {
        isEnabled.toggle()
        return isEnabled
    }
}
