//
//  PinnedMessagesBar.swift
//  MinisApp
//
//  Minis_X — 消息固定 (pinned messages) UI.
//
//  A horizontal strip that floats at the top of a chat: one compact card per
//  pinned message, newest first, each with a small ✕ that unpins it.
//
//      PinnedMessagesBar(
//          sessionId: session.id,
//          onSelect: { messageId in scrollTo(messageId) },
//          onUnpin:  { messageId in PinnedMessagesStore.shared.unpin(messageId: messageId) }
//      )
//
//  ─── iOS 16 constraints honoured ───────────────────────────────────────────
//  * No `onChange` at all: the store is an `ObservableObject` observed with
//    `@ObservedObject`, so SwiftUI re-renders the bar automatically when a pin
//    is added/removed. This sidesteps the single-vs-double-parameter `onChange`
//    API split entirely (the double-parameter / zero-parameter forms are iOS 17).
//  * No iOS 17+ APIs: only `ScrollView`, `ForEach`, `Button`, `onTapGesture`,
//    `overlay(alignment:)`, `foregroundStyle`, `clipShape`, `Divider` — all of
//    which predate iOS 16.
//  * `@ViewBuilder` on `body` lets the empty state return `EmptyView()` while
//    the non-empty state returns the real strip, without `AnyView`.
//
//  Ownership of untwining/unpinning stays with the caller: this view never
//  mutates the store for `onSelect`, and it reports `onUnpin` rather than
//  calling `unpin` itself so the host can add haptics / animations / undo.
//

import SwiftUI

@MainActor
struct PinnedMessagesBar: View {

    /// The conversation whose pins are shown.
    let sessionId: String
    /// Tapped a pin card → caller should scroll to / highlight that message.
    /// Receives `PinnedMessage.messageId`.
    let onSelect: (String) -> Void
    /// Tapped the ✕ on a card. Receives `PinnedMessage.messageId`.
    let onUnpin: (String) -> Void

    /// Observed (not `@StateObject`): the singleton owns the lifetime.
    @ObservedObject private var store = PinnedMessagesStore.shared

    init(sessionId: String,
         onSelect: @escaping (String) -> Void,
         onUnpin: @escaping (String) -> Void) {
        self.sessionId = sessionId
        self.onSelect = onSelect
        self.onUnpin = onUnpin
    }

    // MARK: Body

    @ViewBuilder
    var body: some View {
        if items.isEmpty {
            // 空时不显示 — collapses to zero height, so the host can mount this
            // unconditionally at the top of the chat.
            EmptyView()
        } else {
            strip
        }
    }

    private var items: [PinnedMessage] {
        sessionId.isEmpty ? [] : store.pinned(inSession: sessionId)
    }

    private var strip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items) { item in
                    card(for: item)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(
            Color(UIColor.secondarySystemBackground)
        )
        .overlay(alignment: .bottom) {
            Divider()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Pinned messages"))
    }

    // MARK: Card

    private func card(for item: PinnedMessage) -> some View {
        let preview = item.preview
        let shown = preview.isEmpty ? "…" : preview
        return ZStack(alignment: .topTrailing) {
            HStack(spacing: 6) {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.orange)
                Text(shown)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, 10)
            .padding(.trailing, 22)
            .padding(.vertical, 7)
            .frame(width: 220, alignment: .leading)
            .background(Color(UIColor.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            // A tap gesture (not a Button) so it can sit under the ✕ Button
            // without the nested-button hit-testing failure on iOS 16.
            .onTapGesture { onSelect(item.messageId) }
            .accessibilityAddTraits(.isButton)

            Button {
                onUnpin(item.messageId)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.secondary)
                    .padding(4)
            }
            .buttonStyle(.plain)
            .padding(.top, 1)
            .padding(.trailing, 2)
            .accessibilityLabel(Text("Unpin message"))
        }
        .accessibilityElement(children: .contain)
    }
}

#Preview("Pinned Messages Bar") {
    PinnedMessagesBar(sessionId: "preview-session",
                      onSelect: { _ in },
                      onUnpin: { _ in })
}
