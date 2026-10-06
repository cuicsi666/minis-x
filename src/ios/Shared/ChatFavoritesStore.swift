//
//  ChatFavoritesStore.swift
//  MinisApp
//
//  Minis_X feature #3 — 消息收藏 (message favourites).
//
//  Data layer only: no views, no view model, no SQLite. The public surface is
//  an `ObservableObject` singleton that any SwiftUI view can observe with
//  `@ObservedObject private var favorites = ChatFavoritesStore.shared`.
//
//  ─── Why a JSON file in Application Support (not UserDefaults) ───────────────
//  * A favourite carries the full message body, so the store grows with the
//    user's content, not with their preferences. UserDefaults is documented as
//    the home for small preference values; a multi-hundred-KB blob of chat text
//    in the defaults plist is re-parsed at launch and rewritten on every write,
//    which is exactly the kind of file UserDefaults is bad at.
//  * UserDefaults gives no atomic replace-on-write for large payloads and no
//    schema/versioning story. A real file gets `.atomic` writes (a crash
//    mid-save can never leave a half-written plist) plus Application Support's
//    documented role as the home of app-created data that belongs in backups.
//  * `favorites.json` is inspectable, diffable and exportable outside the app
//    (the file sits in `<container>/Library/Application Support/ChatFavorites/`).
//  * The same choice is already made elsewhere in this codebase for
//    file-backed state (see `EnvVarStore` / `LoggingManager`, both under
//    `Library/`), so this is consistent, not a new pattern.
//  Writes are therefore: JSON-encode on the calling (main) thread, then hand
//  the bytes to a serial utility queue that performs one atomic file replace.
//
//  ─── Decoupling ────────────────────────────────────────────────────────────
//  `FavoriteMessage` stores only `String` / `UUID` / `Date`. It deliberately
//  does NOT reference `ChatMessage` / `ChatMessageRole`, so this file cannot be
//  broken by a refactor of the chat model layer and the persisted JSON stays
//  readable across schema churn. The bridge from the live models is the small
//  extension at the bottom (signatures verified against the source, see there).
//
//  ─── Threading contract ────────────────────────────────────────────────────
//  `favorites` is main-thread affine: every entry point writes the in-memory
//  array synchronously (so a read right after a write is never stale) and then
//  enqueues the disk write off-thread. All call sites in the app are UI
//  callbacks, which are already on the main thread.
//

import Combine
import Foundation

// MARK: - Model

/// One favourited message: a SNAPSHOT of the message taken when the user
/// starred it.
///
/// Snapshot, not a live reference, on purpose:
/// * a favourite must survive the session (or the message) being deleted, which
///   is the whole point of a collection;
/// * the favourites list must render without loading a session's message table;
/// * the assistant turn it points at may still be streaming when it is starred,
///   so "live" would mean a moving target.
/// `ChatFavoritesStore.updateText(_:forMessageId:)` exists for the cases where
/// the caller does want to refresh the stored body.
struct FavoriteMessage: Codable, Identifiable, Equatable, Hashable {

    /// Decoupled mirror of `ChatMessageRole` (verified: `Agent/Chat/ChatModels.swift`
    /// declares exactly `user`, `assistant`, `compactDivider`, `systemInfo`).
    /// Persisted as a `String` so a role added by a future build degrades to
    /// `.unknown` on decode instead of failing the whole favourites file.
    enum Role: String, Codable, CaseIterable, Hashable {
        case user
        case assistant
        case compactDivider
        case systemInfo
        case unknown

        static func normalize(_ raw: String) -> Role { Role(rawValue: raw) ?? .unknown }

        /// Short label for a favourites list row. Plain English source strings;
        /// the main controller may swap these for `AppLocalized("…")` when it
        /// wires the UI (deliberately not called here — this file stays free of
        /// every project symbol except the optional bridge below).
        var displayName: String {
            switch self {
            case .user: return "You"
            case .assistant: return "Assistant"
            case .compactDivider: return "Compaction"
            case .systemInfo: return "System"
            case .unknown: return "Message"
            }
        }
    }

    /// `ChatMessage.id` is `let id = UUID()` — a UUID, not a String.
    let messageId: UUID
    /// `ChatSession.id` is a `String` (verified in `Agent/Chat/ChatStore.swift`).
    let sessionId: String
    let role: Role
    /// The message body captured at favourite time.
    var text: String
    /// `ChatMessage.timestamp` — when the message itself was created.
    let messageCreatedAt: Date
    /// When the user starred it (drives list ordering).
    let favoritedAt: Date

    /// `Identifiable` conformance doubles as "one row per message": a message
    /// can only be favourited once.
    var id: UUID { messageId }

    init(messageId: UUID,
         sessionId: String,
         role: Role,
         text: String,
         messageCreatedAt: Date,
         favoritedAt: Date = Date()) {
        self.messageId = messageId
        self.sessionId = sessionId
        self.role = role
        self.text = text
        self.messageCreatedAt = messageCreatedAt
        self.favoritedAt = favoritedAt
    }

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// One-line preview for list rows / menus.
    var preview: String { FavoriteMessage.oneLinePreview(of: text) }

    /// Whitespace-collapsed, length-capped, single line. Returns "" for blank
    /// input (never a bare "…"). Static (name not `preview`, to leave the
    /// instance property above unambiguous at every call site).
    static func oneLinePreview(of text: String, limit: Int = 80) -> String {
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard limit > 0, collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)) + "…"
    }
}

// MARK: - Store

/// App-wide favourites store.
///
/// Usage (UI):
/// ```swift
/// @ObservedObject private var favorites = ChatFavoritesStore.shared
/// ...
/// if favorites.isFavorited(message.id) { … }
/// ```
final class ChatFavoritesStore: ObservableObject {

    /// Shared instance. `nonisolated(unsafe)` is the same escape hatch
    /// `AppLogger` uses for its cached level: it documents that the store is
    /// deliberately not actor-isolated and keeps the declaration legal if the
    /// target is ever moved to the Swift 6 language mode. All API below is
    /// main-thread affine (see the file header).
    nonisolated(unsafe) static let shared = ChatFavoritesStore()

    /// All favourites, newest favourite first (`favoritedAt` descending).
    /// `private(set)` — every mutation goes through a method here so the file
    /// and the published array can never drift apart.
    @Published private(set) var favorites: [FavoriteMessage] = []

    /// Where the JSON lives. Injectable so tests can point at a temp file.
    let fileURL: URL

    nonisolated(unsafe) private static let logger = AppLogger(category: "ChatFavorites")

    /// Serial queue for disk writes. Serial (not concurrent) so two saves can
    /// never interleave; `.utility` because a favourites save is never urgent.
    private let ioQueue = DispatchQueue(label: "com.cuicsi.minisvps.chat-favorites.io",
                                        qos: .utility)

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? ChatFavoritesStore.defaultFileURL()
        self.favorites = ChatFavoritesStore.read(from: self.fileURL)
    }

    // MARK: Queries

    var isEmpty: Bool { favorites.isEmpty }
    var count: Int { favorites.count }

    /// 查询某条消息是否已收藏. O(n) over the favourites list — hundreds of rows
    /// at most, and it runs inside a menu tap or a row body, not per frame.
    func isFavorited(_ messageId: UUID) -> Bool {
        favorites.contains { $0.messageId == messageId }
    }

    /// Alias kept for readability at call sites phrased as a question
    /// ("isFavorite(messageId:)"). Same implementation.
    func isFavorite(messageId: UUID) -> Bool { isFavorited(messageId) }

    func favorite(withId messageId: UUID) -> FavoriteMessage? {
        favorites.first { $0.messageId == messageId }
    }

    /// One conversation's favourites, newest first.
    func favorites(inSession sessionId: String) -> [FavoriteMessage] {
        favorites.filter { $0.sessionId == sessionId }
    }

    /// All favourites grouped by session; groups are ordered by their newest
    /// favourite, rows keep the newest-first order. For a settings page.
    func groupedBySession() -> [SessionGroup] {
        var order: [String] = []
        var buckets: [String: [FavoriteMessage]] = [:]
        for entry in favorites {
            if buckets[entry.sessionId] == nil {
                buckets[entry.sessionId] = []
                order.append(entry.sessionId)
            }
            buckets[entry.sessionId]?.append(entry)
        }
        return order.map { SessionGroup(sessionId: $0, favorites: buckets[$0] ?? []) }
    }

    /// One session's worth of favourites in the grouped list.
    struct SessionGroup: Identifiable, Equatable {
        let sessionId: String
        var favorites: [FavoriteMessage]
        var id: String { sessionId }
        var newestFavoritedAt: Date { favorites.first?.favoritedAt ?? .distantPast }
    }

    // MARK: Mutations

    /// 收藏一条消息. 收藏一条已收藏的消息 = 幂等刷新 (text / role / timestamp).
    @discardableResult
    func add(messageId: UUID,
             sessionId: String,
             role: FavoriteMessage.Role,
             text: String,
             messageCreatedAt: Date,
             favoritedAt: Date = Date()) -> FavoriteMessage {
        let entry = FavoriteMessage(messageId: messageId,
                                    sessionId: sessionId,
                                    role: role,
                                    text: text,
                                    messageCreatedAt: messageCreatedAt,
                                    favoritedAt: favoritedAt)
        upsert(entry)
        return entry
    }

    @discardableResult
    func add(_ entry: FavoriteMessage) -> FavoriteMessage {
        upsert(entry)
        return entry
    }

    /// 收藏/取消收藏. Returns the resulting state: `true` = now favourited.
    @discardableResult
    func toggle(messageId: UUID,
                sessionId: String,
                role: FavoriteMessage.Role,
                text: String,
                messageCreatedAt: Date) -> Bool {
        if isFavorited(messageId) {
            remove(messageId: messageId)
            return false
        }
        add(messageId: messageId,
            sessionId: sessionId,
            role: role,
            text: text,
            messageCreatedAt: messageCreatedAt)
        return true
    }

    /// Refresh the stored body of an existing favourite. Returns false when the
    /// message is not favourited (nothing written).
    @discardableResult
    func updateText(_ text: String, forMessageId messageId: UUID) -> Bool {
        guard let existing = favorites.first(where: { $0.messageId == messageId }) else {
            return false
        }
        guard existing.text != text else { return true }
        var updated = existing
        updated.text = text
        // Rebuilt array (not in-place element mutation) so the @Published
        // setter definitely fires.
        favorites = favorites.map { $0.messageId == messageId ? updated : $0 }
        persist()
        return true
    }

    /// 取消收藏. Returns true when a row was removed.
    @discardableResult
    func remove(messageId: UUID) -> Bool {
        guard isFavorited(messageId) else { return false }
        favorites = favorites.filter { $0.messageId != messageId }
        persist()
        return true
    }

    /// Drop a whole conversation's favourites (call when the session is
    /// deleted). Returns how many rows went away.
    @discardableResult
    func removeAll(inSession sessionId: String) -> Int {
        let before = favorites.count
        favorites = favorites.filter { $0.sessionId != sessionId }
        let removed = before - favorites.count
        if removed > 0 { persist() }
        return removed
    }

    /// 删除全部收藏. Returns how many rows went away.
    @discardableResult
    func removeAll() -> Int {
        let removed = favorites.count
        guard removed > 0 else { return 0 }
        favorites = []
        persist()
        return removed
    }

    // MARK: Persistence

    /// Re-read the JSON file, discarding unsaved in-memory state.
    func reload() {
        favorites = ChatFavoritesStore.read(from: fileURL)
    }

    /// Block until every enqueued disk write has finished. Diagnostic / test
    /// helper — the UI never needs it.
    func flushPendingWrites() {
        ioQueue.sync {}
    }

    private func upsert(_ entry: FavoriteMessage) {
        var next = favorites
        if let index = next.firstIndex(where: { $0.messageId == entry.messageId }) {
            next[index] = entry
        } else {
            next.append(entry)
        }
        next.sort { $0.favoritedAt > $1.favoritedAt }
        favorites = next
        persist()
    }

    /// Encode on the caller's thread, then write atomically off-thread. The
    /// snapshot is taken here, so a later mutation cannot race the write.
    private func persist() {
        let snapshot = favorites
        let url = fileURL
        let data: Data
        do {
            data = try ChatFavoritesStore.makeEncoder().encode(snapshot)
        } catch {
            ChatFavoritesStore.logger.error("[ChatFavorites] encode failed: \(error.localizedDescription)")
            return
        }
        ioQueue.async {
            do {
                try data.write(to: url, options: [.atomic])
            } catch {
                ChatFavoritesStore.logger.error("[ChatFavorites] write failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Storage plumbing

    /// `<Application Support>/ChatFavorites/favorites.json`.
    static func defaultFileURL() -> URL {
        let fm = FileManager.default
        let base: URL
        if let appSupport = try? fm.url(for: .applicationSupportDirectory,
                                        in: .userDomainMask,
                                        appropriateFor: nil,
                                        create: true) {
            base = appSupport
        } else {
            // Documented fallback: `urls(for:in:)` -> first element.
            base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fm.temporaryDirectory
        }
        let directory = base.appendingPathComponent("ChatFavorites", isDirectory: true)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("favorites.json", isDirectory: false)
    }

    /// A fresh encoder per call: saves are rare (one per user action), and this
    /// keeps the type free of a shared, non-Sendable JSONEncoder instance.
    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// 跨启动加载. A missing file is a normal empty store. An unreadable file is
    /// quarantined (renamed, never deleted) before we start empty, so a decode
    /// bug can be diagnosed from the real bytes instead of a silent loss.
    private static func read(from url: URL) -> [FavoriteMessage] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            let rows = try makeDecoder().decode([FavoriteMessage].self, from: data)
            return sanitize(rows)
        } catch {
            logger.error("[ChatFavorites] load failed at \(url.path): \(error.localizedDescription)")
            quarantineCorruptFile(at: url)
            return []
        }
    }

    /// Newest first, one row per message id (defensive: a hand-edited or
    /// partially-written file cannot produce duplicate rows).
    private static func sanitize(_ rows: [FavoriteMessage]) -> [FavoriteMessage] {
        var seen = Set<UUID>()
        var out: [FavoriteMessage] = []
        for row in rows.sorted(by: { $0.favoritedAt > $1.favoritedAt }) {
            guard seen.insert(row.messageId).inserted else { continue }
            out.append(row)
        }
        return out
    }

    private static func quarantineCorruptFile(at url: URL) {
        let stamp = Int(Date().timeIntervalSince1970)
        let backup = url.deletingPathExtension()
            .appendingPathExtension("corrupt-\(stamp).json")
        try? FileManager.default.moveItem(at: url, to: backup)
    }
}

// MARK: - Bridge to the live chat models
//
// Signatures below were read out of the source before being referenced (never
// guessed):
//   Agent/Chat/ChatModels.swift
//     final class ChatMessage: Identifiable, ObservableObject
//     let id = UUID()
//     let role: ChatMessageRole
//     @Published var content: String
//     @Published var blocks: [AssistantBlock] = []
//     let timestamp = Date()
//   Agent/Chat/ChatModels.swift
//     enum ChatMessageRole { case user, assistant, compactDivider, systemInfo }
//     enum AssistantBlockKind: Equatable { case text, thinking, shellTool(command:),
//       fileReadTool(path:), fileWriteTool(path:), fileEditTool(path:),
//       browserTool(action:), readImageTool(path:), memoryTool(action:), … }
//   Agent/Chat/ChatStore.swift
//     struct ChatSession: Identifiable, Codable, Hashable { let id: String; … }
//
// A future case added to either enum degrades to `.unknown` rather than
// breaking this file (that is why the role switches below use `default`).

extension ChatFavoritesStore {

    /// The text worth storing for a message.
    ///
    /// `ChatMessage.content` holds the whole body for a user row, and for a
    /// plain assistant reply. A streamed assistant turn can however have an
    /// EMPTY `content` with its prose living in `.text` blocks, so fall back to
    /// joining those (same rule the message row uses for "Copy All").
    static func captureText(of message: ChatMessage) -> String {
        let direct = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !direct.isEmpty { return message.content }
        return message.blocks
            .filter { block in
                if case .text = block.kind { return true }
                return false
            }
            .map(\.content)
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func favoriteRole(for role: ChatMessageRole) -> FavoriteMessage.Role {
        switch role {
        case .user: return .user
        case .assistant: return .assistant
        default: return .unknown
        }
    }

    /// 收藏一条消息 (`sessionId` = `ChatSession.id`).
    /// Pass `text:` when the caller has a better body than `captureText(of:)`
    /// (e.g. the row's `fullReplyText`).
    @discardableResult
    func favorite(_ message: ChatMessage,
                  sessionId: String,
                  text: String? = nil) -> FavoriteMessage {
        add(messageId: message.id,
            sessionId: sessionId,
            role: ChatFavoritesStore.favoriteRole(for: message.role),
            text: text ?? ChatFavoritesStore.captureText(of: message),
            messageCreatedAt: message.timestamp)
    }

    /// 收藏/取消收藏. Returns `true` when the message ended up favourited.
    @discardableResult
    func toggle(_ message: ChatMessage,
                sessionId: String,
                text: String? = nil) -> Bool {
        if isFavorited(message.id) {
            remove(messageId: message.id)
            return false
        }
        favorite(message, sessionId: sessionId, text: text)
        return true
    }

    func remove(_ message: ChatMessage) {
        remove(messageId: message.id)
    }

    func isFavorited(_ message: ChatMessage) -> Bool {
        isFavorited(message.id)
    }
}
