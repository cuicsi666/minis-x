//
//  FavoritesListView.swift
//  MinisApp
//
//  Minis_X feature #3 (UI) — 消息收藏列表.
//
//  The read side of `ChatFavoritesStore`. The store already owns the data
//  layer (JSON in Application Support, `@Published favorites`, grouping and
//  removal); this file is presentation only and adds no state of its own
//  beyond what SwiftUI needs to render:
//
//      FavoritesListView { sessionId, messageId in … }   // 打开命中消息
//
//  ─── Contract with ChatFavoritesStore (read, not guessed) ──────────────────
//    ChatFavoritesStore.shared                  // ObservableObject singleton
//    @Published private(set) var favorites: [FavoriteMessage]
//    func groupedBySession() -> [SessionGroup]  // SessionGroup: Identifiable
//    func remove(messageId: UUID) -> Bool       // @discardableResult
//    FavoriteMessage: Identifiable, Equatable, Hashable
//      messageId: UUID, sessionId: String, role: Role,
//      text: String, preview: String, messageCreatedAt: Date, favoritedAt: Date
//    FavoriteMessage.Role: user / assistant / compactDivider / systemInfo / unknown
//
//  Note on ordering: `groupedBySession()` emits groups and rows in the
//  store's order, which is `favoritedAt` descending, so no sorting happens
//  here — the view must never re-order or the list would drift from the store.
//
//  Note on role labels: `FavoriteMessage.Role.displayName` ships English
//  source strings ("You" / "Assistant" / …) and is deliberately kept free of
//  the project's localisation helper. The Chinese labels below are therefore
//  owned by this view; the switch is exhaustive over the current cases so a
//  future case is a compile error here instead of a silent wrong label.
//

import Foundation
import SwiftUI

@MainActor
struct FavoritesListView: View {

    /// Fired when a row is tapped, with (`sessionId`, `messageId`) — the caller
    /// opens that conversation and scrolls to that message.
    private let onSelect: (String, UUID) -> Void

    @ObservedObject private var store = ChatFavoritesStore.shared
    @Environment(\.dismiss) private var dismiss

    init(onSelect: @escaping (String, UUID) -> Void) {
        self.onSelect = onSelect
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            Group {
                if store.favorites.isEmpty {
                    emptyState
                } else {
                    favoritesList
                }
            }
            .navigationTitle("收藏")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    // MARK: List

    private var favoritesList: some View {
        List {
            ForEach(store.groupedBySession()) { group in
                Section {
                    ForEach(group.favorites) { favorite in
                        row(favorite, sessionId: group.sessionId)
                    }
                } header: {
                    sectionHeader(for: group)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func sectionHeader(for group: ChatFavoritesStore.SessionGroup) -> some View {
        HStack(spacing: 8) {
            // Session ids are UUID-ish strings; a middle truncation keeps both
            // ends recognisable instead of a wall of identical prefixes.
            Text(FavoritesListView.shortSessionId(group.sessionId))
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
            Text("\(group.favorites.count) 条")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func row(_ favorite: FavoriteMessage, sessionId: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(FavoritesListView.roleLabel(favorite.role))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(FavoritesListView.roleColor(favorite.role))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(
                        FavoritesListView.roleColor(favorite.role).opacity(0.14),
                        in: Capsule()
                    )
                Spacer(minLength: 4)
                Text(FavoritesListView.relativeText(for: favorite.favoritedAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Text(rowText(favorite))
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { onSelect(sessionId, favorite.messageId) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("打开这条收藏消息")
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                withAnimation {
                    _ = store.remove(messageId: favorite.messageId)
                }
            } label: {
                Label("取消收藏", systemImage: "trash")
            }
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "star")
                .font(.system(size: 38))
                .foregroundStyle(.tertiary)
            Text("还没有收藏的消息")
                .font(.headline)
            Text("在聊天里长按任意消息，选择「收藏」，它就会出现在这里。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    // MARK: Row helpers

    /// `preview` is the store's collapsed one-liner; blank text (a tool-only
    /// turn starred by mistake) still needs a visible row.
    private func rowText(_ favorite: FavoriteMessage) -> String {
        let preview = favorite.preview
        return preview.isEmpty ? "（空消息）" : preview
    }

    private static func shortSessionId(_ id: String) -> String {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "未命名会话" }
        guard trimmed.count > 12 else { return trimmed }
        return String(trimmed.prefix(8)) + "…" + String(trimmed.suffix(3))
    }

    private static func roleLabel(_ role: FavoriteMessage.Role) -> String {
        switch role {
        case .user: return "我"
        case .assistant: return "助手"
        case .compactDivider: return "压缩标记"
        case .systemInfo: return "系统"
        case .unknown: return "消息"
        }
    }

    private static func roleColor(_ role: FavoriteMessage.Role) -> Color {
        switch role {
        case .user: return .blue
        case .assistant: return .purple
        case .compactDivider: return .orange
        case .systemInfo: return .gray
        case .unknown: return .teal
        }
    }

    /// "3 分钟前" / "2 天前", always in Chinese regardless of the app language
    /// (this sheet's copy is Chinese). `MainActor`-isolated static storage is
    /// concurrency-safe under the target's Swift 6 mode — same shape as the
    /// `static let` formatters in `UsageStatsView` / `FileBrowserView`.
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh-Hans")
        formatter.unitsStyle = .short
        return formatter
    }()

    private static func relativeText(for date: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}
