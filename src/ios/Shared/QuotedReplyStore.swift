//
//  QuotedReplyStore.swift
//  MinisApp
//
//  Minis_X feature #10 — 引用回复 (quoted reply).
//
//  Holds exactly ONE pending quote: the message the user long-pressed
//  "Reply" on and that the composer is now showing above the text field. The
//  UI writes it (`set`), the input bar reads/displays it, and the send path
//  folds it into the outgoing prompt and clears it (`consumePrompt(with:)`).
//
//  ─── Why this is NOT persisted ─────────────────────────────────────────────
//  A pending quote is DRAFT state, exactly like the text in the composer —
//  which this app also does not persist. Writing it to disk would resurrect a
//  "正在引用: …" strip after a relaunch with no draft to attach it to, i.e. a
//  banner the user cannot explain and did not ask for. It also must not leak
//  across conversations, which is what `clearIfOtherSession(_:)` is for.
//  Nothing here is lost by keeping it in memory: a quote only exists for as
//  long as the composer it decorates.
//
//  ─── Decoupling ────────────────────────────────────────────────────────────
//  `QuotedReply` stores only `String` / `UUID` / `Date`, mirroring the choice
//  made in `ChatFavoritesStore.swift` — no dependency on `ChatMessage`, so the
//  persisted/held shape cannot be broken by chat-model churn. The optional
//  bridge to the live models is the last extension in this file.
//
//  Threading: main-thread affine, same contract as `ChatFavoritesStore`.
//

import Combine
import Foundation
import SwiftUI

// MARK: - Model

/// The message currently being quoted. Pure data.
struct QuotedReply: Identifiable, Equatable, Codable {

    /// Decoupled mirror of `ChatMessageRole`; only the two roles a user can
    /// meaningfully reply to are modelled, everything else degrades to
    /// `.unknown` (never a decode failure).
    enum Role: String, Codable, CaseIterable, Hashable {
        case user
        case assistant
        case unknown

        static func normalize(_ raw: String) -> Role { Role(rawValue: raw) ?? .unknown }

        /// Human label ("You" / "Assistant") for the composer strip.
        var displayName: String {
            switch self {
            case .user: return "You"
            case .assistant: return "Assistant"
            case .unknown: return "Message"
            }
        }

        /// How the role is named INSIDE the prompt handed to the model, so it
        /// can tell whose words it is looking at.
        var promptLabel: String {
            switch self {
            case .user: return "the user"
            case .assistant: return "you (the assistant)"
            case .unknown: return "an earlier message"
            }
        }
    }

    /// `ChatMessage.id` — a UUID.
    let messageId: UUID
    /// `ChatSession.id` — a String.
    let sessionId: String
    let role: Role
    /// Body captured when the user tapped Reply (snapshot; see `QuotedReplyStore`).
    let text: String
    /// `ChatMessage.timestamp`.
    let messageCreatedAt: Date
    /// When the user tapped "Reply" (not persisted; kept for debugging/ordering).
    let quotedAt: Date

    var id: UUID { messageId }

    init(messageId: UUID,
         sessionId: String,
         role: Role,
         text: String,
         messageCreatedAt: Date,
         quotedAt: Date = Date()) {
        self.messageId = messageId
        self.sessionId = sessionId
        self.role = role
        self.text = text
        self.messageCreatedAt = messageCreatedAt
        self.quotedAt = quotedAt
    }

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// One-line composer-strip preview.
    var preview: String { QuotedReply.oneLinePreview(of: text) }

    /// Static helper, named so it cannot collide with the instance `preview`.
    static func oneLinePreview(of text: String, limit: Int = 120) -> String {
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard limit > 0, collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)) + "…"
    }

    /// `> `-prefixed block, newline structure preserved, length capped.
    func quotedBlock(limit: Int = 600) -> String {
        let clamped = QuotedReply.clamp(text, limit: limit)
        let body = clamped.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return ">" }
        return body
            .components(separatedBy: .newlines)
            .map { "> " + $0 }
            .joined(separator: "\n")
    }

    /// Hard character cap that does not slice mid-line when it can avoid it.
    static func clamp(_ text: String, limit: Int) -> String {
        guard limit > 0, text.count > limit else { return text }
        let head = String(text.prefix(limit))
        if let lastBreak = head.lastIndex(where: { $0 == "\n" }) {
            let line = String(head[head.startIndex..<lastBreak])
            if line.count >= limit / 2 { return line + "\n…" }
        }
        return head + "…"
    }
}

// MARK: - Store

/// Holds the single pending quote for the active composer.
final class QuotedReplyStore: ObservableObject {

    /// Shared instance (`nonisolated(unsafe)` as documented in
    /// `ChatFavoritesStore`).
    nonisolated(unsafe) static let shared = QuotedReplyStore()

    /// The pending quote, or nil when nothing is being quoted. `private(set)`:
    /// mutate through `set(_:)` / `clear()` / `consumePrompt(with:)` so the
    /// banner and the outgoing prompt can never disagree.
    @Published private(set) var current: QuotedReply?

    init(current: QuotedReply? = nil) {
        self.current = current
    }

    /// Whether the composer should show the 「正在引用」strip.
    var hasQuote: Bool { current != nil }

    // MARK: set / clear / read

    /// Set (or replace) the pending quote.
    func set(_ reply: QuotedReply) {
        current = reply
    }

    /// Convenience setter for the common "quote this message" call.
    @discardableResult
    func set(messageId: UUID,
             sessionId: String,
             role: QuotedReply.Role,
             text: String,
             messageCreatedAt: Date) -> QuotedReply {
        let reply = QuotedReply(messageId: messageId,
                                sessionId: sessionId,
                                role: role,
                                text: text,
                                messageCreatedAt: messageCreatedAt)
        current = reply
        return reply
    }

    /// 清除当前引用 (user tapped ✕, or the message was sent).
    func clear() {
        guard current != nil else { return }
        current = nil
    }

    /// Drop the pending quote unless it belongs to `sessionId`. Call from a
    /// session-switch hot spot — a quote from another conversation must never
    /// be attached to a message in this one.
    func clearIfOtherSession(_ sessionId: String?) {
        guard let reply = current else { return }
        guard reply.sessionId != (sessionId ?? "") else { return }
        self.current = nil
    }

    // MARK: Send-path helpers

    /// The prompt block the model sees, e.g.
    ///
    ///     [Quoted reply — the user is replying to an earlier message from the user]
    ///     > 那条消息的原文…
    ///
    /// The wording is deliberately explicit and English-only: it is read by the
    /// model, not by the user, and it must not be translated into something the
    /// model can misread.
    static func contextBlock(for reply: QuotedReply) -> String {
        let quotedBody = reply.quotedBlock()
        return """
        [Quoted reply — the user is replying to an earlier message from \(reply.role.promptLabel)]
        \(quotedBody)
        """
    }

    /// Prefix `userText` with the quote block. Non-destructive (the banner
    /// stays). Returns `userText` unchanged when nothing is quoted, or when the
    /// draft is empty (an empty draft must not become a quote-only message).
    func composePrompt(with userText: String) -> String {
        guard let reply = current else { return userText }
        guard !userText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return userText
        }
        return QuotedReplyStore.contextBlock(for: reply) + "\n\n" + userText
    }

    /// Send-path helper: compose, then clear. Call exactly once, right where the
    /// draft is dispatched.
    ///
    /// The quote is only consumed when it actually landed in a non-empty draft,
    /// so a stray send on an empty composer does not silently throw away the
    /// quote the user just set up.
    func consumePrompt(with userText: String) -> String {
        guard current != nil else { return userText }
        let composed = composePrompt(with: userText)
        if !userText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            current = nil
        }
        return composed
    }
}

// MARK: - Bridge to the live chat models

extension QuotedReplyStore {

    /// Same rule as `ChatFavoritesStore.captureText(of:)` — an assistant reply
    /// that streamed into blocks has an empty `content`.
    static func captureText(of message: ChatMessage) -> String {
        ChatFavoritesStore.captureText(of: message)
    }

    static func replyRole(for role: ChatMessageRole) -> QuotedReply.Role {
        switch role {
        case .user: return .user
        case .assistant: return .assistant
        default: return .unknown
        }
    }

    /// Quote a message the user just long-pressed "Reply" on.
    @discardableResult
    func quote(_ message: ChatMessage,
               sessionId: String,
               text: String? = nil) -> QuotedReply {
        set(messageId: message.id,
            sessionId: sessionId,
            role: QuotedReplyStore.replyRole(for: message.role),
            text: text ?? QuotedReplyStore.captureText(of: message),
            messageCreatedAt: message.timestamp)
    }

    /// True when `message` is the one currently being quoted (lets the menu
    /// label read "Cancel Reply" instead of "Reply").
    func isQuoting(_ message: ChatMessage) -> Bool {
        current?.messageId == message.id
    }
}

// MARK: - Composer strip (optional, pure SwiftUI)

/// The 「正在引用: …」 strip the composer draws above the text field.
///
/// Presentation only — it reads a value handed to it, never the store, so the
/// host view decides when it appears (see the integration notes). Uses nothing
/// but SwiftUI system styles, so it renders correctly before the host's own
/// colour constants are involved.
struct QuotedReplyBanner: View {
    let reply: QuotedReply
    /// ✕ / swipe → clear the pending quote.
    var onCancel: () -> Void
    /// Optional: tap the strip to jump back to the quoted message.
    var onTap: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Color.accentColor)
                .frame(width: 3, height: 26)

            Image(systemName: "arrowshape.turn.up.left.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            Text("Replying to:")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .fixedSize()

            Text(reply.preview)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Cancel quote"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { onTap?() }
    }
}
