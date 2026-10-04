//
//  MessageSpeechService.swift
//  MinisApp
//
//  Minis_X feature #9 — 回复朗读 (read-aloud / TTS for a single reply).
//
//  A single, self-contained, on-device TTS engine: "read THIS message aloud",
//  driven from a message long-press menu. It is intentionally independent of the
//  heavier read-replies pipeline (AIChatViewModel's streaming auto-narration +
//  cloud VoiceOutputPlayer) so it can be unit-tested on its own and reused by any
//  surface (chat list, file preview, share sheet).
//
//  Public surface — an `ObservableObject` singleton a SwiftUI view observes:
//
//      @ObservedObject private var speech = MessageSpeechService.shared
//      ...
//      speech.toggle(message.content, messageId: message.id)
//      let isThisRow = speech.isSpeakingMessage(id: message.id)   // row highlight
//
//  ─── Engine ────────────────────────────────────────────────────────────────
//  AVSpeechSynthesizer + AVSpeechUtterance (on-device, offline, no network cost).
//  Voice resolution prefers the requested language (`AVSpeechSynthesisVoice(
//  language:)`, default "zh-CN"), then any installed voice whose language shares
//  the requested prefix, then zh-CN, then the system default. Rate ≈ 0.5
//  (= AVSpeechUtteranceDefaultSpeechRate), pitch 1.0, volume 1.0.
//
//  ─── Why long text is split ────────────────────────────────────────────────
//  One utterance holding a whole multi-KB Markdown reply makes the synthesizer
//  buffer everything before the first word is audible, and `stopSpeaking` only
//  lands on an utterance boundary. So the text is first cut on punctuation into
//  "pieces", the pieces are greedily packed into segments of ≤ 300 characters
//  (hard-split at the last whitespace if a single piece is longer), and the
//  segments are spoken ONE AT A TIME — the next one is started from
//  `didFinish` of the previous. `isSpeaking` therefore stays `true` across the
//  whole run and only flips to `false` after the LAST segment has finished (or
//  after `stop()`), which is what the UI needs for the 朗读/停止朗读 toggle.
//
//  ─── AVAudioSession: deliberately NOT configured here ──────────────────────
//  This file never calls `setCategory(_:)` / `setActive(_:)` / `setMode(_:)`.
//  Reasons (documented here because the omission looks like an oversight):
//    • Minis_X already has ONE owner of the audio session — `AudioSessionCoordinator`
//      — which ranks intents (.capture > .mediaAttachment > .replyTTS >
//      .backgroundKeepAlive) and applies exactly one category. A second writer in
//      this service would reintroduce the "last writer wins" category race that
//      the coordinator was written to remove.
//    • The fragile case is the mic: setting `.playback` while the voice-input
//      engine is capturing tears the record session down. Read-aloud must never
//      be able to do that from inside its own speak() path.
//    • AVSpeechSynthesizer plays through the app's existing session
//      (`usesApplicationAudioSession` defaults to `true`), so no explicit
//      session work is needed for audio to come out.
//  Integration contract: the CALLER declares/ends the `.replyTTS` intent on
//  `AudioSessionCoordinator` around speak()/stop() — see the delivery report for
//  the paste-ready snippet. This keeps the service testable with no audio session
//  at all, and keeps audio policy in one place.
//
//  ─── Threading ─────────────────────────────────────────────────────────────
//  The class is deliberately NOT `@MainActor`: `AVSpeechSynthesizerDelegate` is an
//  @objc protocol that can deliver callbacks off the main thread, and annotating
//  the class would either world-isolate those methods or trip the conformance
//  under strict concurrency. Instead every state read/write goes through the
//  `onMain` trampoline below, so ALL `@Published` mutations land on the main
//  thread and callers may invoke speak()/stop()/toggle() from any queue.
//

import AVFoundation
import Combine
import Foundation

final class MessageSpeechService: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {

    // MARK: - Shared instance

    /// App-wide engine. `nonisolated(unsafe)` mirrors the rest of `Shared/`
    /// (see `ChatFavoritesStore.shared`): the instance is intentionally not
    /// actor-isolated — all mutable state is confined to the main thread by the
    /// `onMain` trampoline, and `AVSpeechSynthesizer.speak` is itself thread-safe
    /// on Apple's side.
    nonisolated(unsafe) static let shared = MessageSpeechService()

    // MARK: - Published state (main-thread only; read-only by convention)

    /// `true` from the moment `speak()`/`toggle()` starts a run until the last
    /// segment finishes, the run is cancelled by `stop()`, or the system cancels
    /// the utterance. Drive the menu label from this:
    /// 「朗读」when false, 「停止朗读」when true.
    @Published var isSpeaking: Bool = false

    /// Which message is being read right now (`nil` when idle). Optional — only
    /// for UI highlighting; a caller that passes no id just gets `nil` here.
    /// Always cleared together with `isSpeaking`.
    @Published var currentMessageId: String?

    // MARK: - Tunables

    /// Default utterance language (feature spec: zh-CN).
    static let defaultLanguage = "zh-CN"
    /// ≈ AVSpeechUtteranceDefaultSpeechRate. 0.5 is a comfortable reading pace;
    /// raise it (max 1.0) for a faster narrator.
    static let defaultRate: Float = 0.5
    static let defaultPitchMultiplier: Float = 1.0
    static let defaultVolume: Float = 1.0
    /// Hard ceiling for a single utterance. Long enough to sound natural, short
    /// enough that `stop()` lands quickly and the synthesizer never buffers a novel.
    static let maxSegmentLength = 300

    /// Optional voice pin: an `AVSpeechSynthesisVoice.identifier` (e.g. the value
    /// stored by the app's Speech settings). Leave `nil` to let the per-call
    /// `language` decide. An unknown identifier silently falls back.
    var preferredVoiceIdentifier: String?

    // MARK: - Private state (main-thread only)

    private let synthesizer = AVSpeechSynthesizer()
    /// Segments of the current run, spoken in order.
    private var segments: [String] = []
    /// Index of the next segment to speak.
    private var nextSegmentIndex = 0
    /// Language of the current run (resolved to a voice per segment).
    private var activeLanguage: String = MessageSpeechService.defaultLanguage
    /// The one utterance the synthesizer is working on right now. Its IDENTITY is
    /// the whole staleness guard: a `didFinish`/`didCancel` for anything other
    /// than this exact object is a callback from a superseded run and is dropped,
    /// and because exactly one utterance is ever in flight it also orders the
    /// segment chain.
    private var currentUtterance: AVSpeechUtterance?

    private override init() {
        super.init()
        synthesizer.delegate = self   // delegate is weak — no retain cycle
    }

    // MARK: - Public API

    /// Read `text` aloud.
    ///
    /// - Parameters:
    ///   - text: raw message body. Markdown is tolerated, but for a nicer listen
    ///     strip code fences / URLs first (`MarkdownStripper` lives in `Shared/`).
    ///     Empty / whitespace-only text simply stops the current run.
    ///   - messageId: optional id, published as `currentMessageId` for row highlight.
    ///   - language: BCP-47 tag. Defaults to `defaultLanguage` ("zh-CN").
    ///
    /// Calling `speak` while another run is in flight cancels it and starts the new
    /// one (never two replies at once). Safe to call from any thread.
    func speak(_ text: String,
               messageId: String? = nil,
               language: String = MessageSpeechService.defaultLanguage) {
        let prepared = MessageSpeechService.segments(from: text)
        onMain { [weak self] in
            guard let self else { return }
            if prepared.isEmpty {
                self.stopLocked()
            } else {
                self.startLocked(segments: prepared, messageId: messageId, language: language)
            }
        }
    }

    /// Cancel the run and reset the published state. Idempotent and safe to call
    /// from any thread, including when nothing is playing (and as a defensive
    /// "reset" after an audio interruption).
    func stop() {
        onMain { [weak self] in self?.stopLocked() }
    }

    /// One action for a long-press menu: 朗读 / 停止朗读.
    /// Stops when *this* message is the one being read (or, when no id is given,
    /// when anything is being read); otherwise starts (or restarts) the run.
    func toggle(_ text: String,
                messageId: String? = nil,
                language: String = MessageSpeechService.defaultLanguage) {
        let prepared = MessageSpeechService.segments(from: text)
        onMain { [weak self] in
            guard let self else { return }
            let isCurrentMessage = (messageId == nil) || (self.currentMessageId == messageId)
            if self.isSpeaking && isCurrentMessage {
                self.stopLocked()
            } else if prepared.isEmpty {
                self.stopLocked()
            } else {
                self.startLocked(segments: prepared, messageId: messageId, language: language)
            }
        }
    }

    /// Convenience for row highlighting: is THIS message the one being read?
    func isSpeakingMessage(id: String) -> Bool {
        isSpeaking && currentMessageId == id
    }

    // MARK: - Run control (main thread only)

    /// Start a fresh run, invalidating whatever was in flight.
    private func startLocked(segments: [String], messageId: String?, language: String) {
        // Invalidate the old run FIRST: clearing `currentUtterance` makes the
        // didCancel that `stopSpeaking` is about to deliver a no-op, so a restart
        // can never flip isSpeaking back to false mid-run.
        currentUtterance = nil
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }

        self.segments = segments
        nextSegmentIndex = 0
        activeLanguage = language
        isSpeaking = true
        currentMessageId = messageId
        speakNextSegmentLocked()
    }

    /// Speak the next segment (or finish the run when none are left).
    private func speakNextSegmentLocked() {
        guard nextSegmentIndex < segments.count else {
            finishRunLocked()
            return
        }
        let segment = segments[nextSegmentIndex]
        nextSegmentIndex += 1

        let utterance = AVSpeechUtterance(string: segment)
        utterance.voice = MessageSpeechService.voice(for: activeLanguage,
                                                    preferredIdentifier: preferredVoiceIdentifier)
        utterance.rate = MessageSpeechService.defaultRate
        utterance.pitchMultiplier = MessageSpeechService.defaultPitchMultiplier
        utterance.volume = MessageSpeechService.defaultVolume
        // The segment boundary is already punctuation, so no extra silence.
        utterance.preUtteranceDelay = 0
        utterance.postUtteranceDelay = 0

        currentUtterance = utterance
        synthesizer.speak(utterance)
    }

    /// The whole run ended naturally (last segment spoken) — go idle.
    private func finishRunLocked() {
        currentUtterance = nil
        segments = []
        nextSegmentIndex = 0
        // Guarded writes: assigning an unchanged value would publish a useless
        // objectWillChange and re-render every observing row.
        if isSpeaking { isSpeaking = false }
        if currentMessageId != nil { currentMessageId = nil }
    }

    /// Cancel everything and go idle.
    private func stopLocked() {
        segments = []
        nextSegmentIndex = 0
        let hadUtterance = currentUtterance != nil
        currentUtterance = nil
        if hadUtterance || synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
        if isSpeaking { isSpeaking = false }
        if currentMessageId != nil { currentMessageId = nil }
    }

    // MARK: - AVSpeechSynthesizerDelegate
    //
    // Callbacks are hopped onto the main thread; `currentUtterance` identity is
    // the guard that makes a late callback from a cancelled run harmless.

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        onMain { [weak self] in
            guard let self, self.currentUtterance === utterance else { return }
            if !self.isSpeaking { self.isSpeaking = true }
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        onMain { [weak self] in
            guard let self, self.currentUtterance === utterance else { return }
            self.currentUtterance = nil
            // Chain the next segment: isSpeaking stays true for the whole run and
            // only finishRunLocked() (the last segment) flips it back to false.
            self.speakNextSegmentLocked()
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        onMain { [weak self] in
            // A cancel for the CURRENT utterance means playback was stopped by
            // something outside this service (audio interruption, route change,
            // another synthesizer call) → go idle so the UI never sticks on
            // 「停止朗读」. A cancel for a stale utterance is ignored: startLocked /
            // stopLocked already reset the state synchronously.
            guard let self, self.currentUtterance === utterance else { return }
            self.finishRunLocked()
        }
    }

    // MARK: - Main-thread trampoline

    /// Run `block` on the main thread. Runs inline when already there, so the
    /// common (UI) path stays synchronous and `isSpeaking` is already correct by
    /// the time `speak()` returns.
    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }

    // MARK: - Text segmentation (pure, thread-safe, unit-testable)

    /// Split `text` into utterance-sized chunks:
    ///   1. cut after every terminator / newline into "pieces" (punctuation kept,
    ///      surrounding whitespace trimmed),
    ///   2. greedily pack consecutive pieces into segments of ≤ `maxLength`,
    ///   3. hard-split any single piece longer than `maxLength`, preferring the
    ///      last whitespace inside each window so words are not cut in half.
    ///
    /// Returns `[]` for empty / whitespace-only input, which callers treat as
    /// "stop" — so a blank message can never leave the UI stuck in speaking state.
    static func segments(from text: String,
                         maxLength: Int = MessageSpeechService.maxSegmentLength) -> [String] {
        let limit = max(1, maxLength)
        var out: [String] = []
        var buffer = ""

        func flushBuffer() {
            let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { out.append(trimmed) }
            buffer = ""
        }

        for piece in pieces(from: text) {
            if piece.count > limit {
                flushBuffer()
                out.append(contentsOf: hardSplit(piece, limit: limit))
                continue
            }
            let separator = buffer.isEmpty
                ? ""
                : (needsSpace(from: buffer, to: piece) ? " " : "")
            let candidate = buffer + separator + piece
            if candidate.count <= limit {
                buffer = candidate
            } else {
                flushBuffer()
                buffer = piece
            }
        }
        flushBuffer()
        return out
    }

    /// Punctuation that ends a spoken unit: CJK + ASCII sentence and clause marks,
    /// plus newline (a Markdown line break is a natural pause). Pure rules, no
    /// dependency on the tokenizer stack.
    private static let pieceTerminators: Set<Character> = [
        "。", "！", "？", "；", "…", "!", "?", ";", "\n",
        "，", "、", "：", ",", ":", ".",
    ]

    private static func pieces(from text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if pieceTerminators.contains(character) {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { out.append(trimmed) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { out.append(tail) }
        return out
    }

    /// Break an over-long piece into ≤ `limit` chunks, preferring the last
    /// whitespace inside each window.
    private static func hardSplit(_ text: String, limit: Int) -> [String] {
        var out: [String] = []
        var remaining = Substring(text)
        // `max(1, limit / 2)` also guarantees forward progress: the cut is never
        // at the window start, so the loop always consumes ≥ 1 character.
        let minimumCut = max(1, limit / 2)

        while remaining.count > limit {
            let window = remaining.prefix(limit)
            var cut = window.endIndex
            if let whitespace = window.lastIndex(where: { $0.isWhitespace }),
               remaining.distance(from: remaining.startIndex, to: whitespace) >= minimumCut {
                cut = whitespace
            }
            let chunk = remaining[remaining.startIndex..<cut]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunk.isEmpty { out.append(chunk) }
            remaining = remaining[cut...].drop(while: { $0.isWhitespace })
        }

        let tail = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { out.append(tail) }
        return out
    }

    /// True when joining `a` + `b` needs a separator: both sides are ASCII
    /// letters/digits. CJK reads fine without a space, and boundaries are usually
    /// punctuation anyway — this only fires on punctuation-free runs (and for
    /// digits it is a no-op because the split kept the punctuation).
    private static func needsSpace(from a: String, to b: String) -> Bool {
        guard let last = a.last, let first = b.first else { return false }
        return isASCIIAlphanumeric(last) && isASCIIAlphanumeric(first)
    }

    private static func isASCIIAlphanumeric(_ character: Character) -> Bool {
        guard character.isASCII else { return false }
        return character.isLetter || character.isNumber
    }

    // MARK: - Voice selection

    /// Resolve a voice for `language`.
    ///
    /// Order: pinned identifier → exact language tag → any installed voice sharing
    /// the requested two-letter prefix (zh-CN → zh) → `defaultLanguage` → nil
    /// (nil = the system default voice, which is never worse than silence).
    ///
    /// Deliberately no "pick the highest quality voice" heuristic: premium voices
    /// can be listed but not downloaded, and speaking through an unavailable voice
    /// yields silence. The system's own pick for the language always works.
    private static func voice(for language: String,
                              preferredIdentifier: String?) -> AVSpeechSynthesisVoice? {
        if let identifier = preferredIdentifier,
           !identifier.isEmpty,
           let pinned = AVSpeechSynthesisVoice(identifier: identifier) {
            return pinned
        }

        let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
        let requested = trimmed.isEmpty ? defaultLanguage : trimmed

        if let exact = AVSpeechSynthesisVoice(language: requested) { return exact }

        let prefix = String(requested.prefix(2)).lowercased()
        if !prefix.isEmpty,
           let sibling = AVSpeechSynthesisVoice.speechVoices()
               .first(where: { $0.language.lowercased().hasPrefix(prefix) }) {
            return sibling
        }

        return AVSpeechSynthesisVoice(language: defaultLanguage)
    }
}
