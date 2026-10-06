//
//  PinnedMessagesStore.swift
//  MinisApp
//
//  Minis_X — 消息固定 (pinned messages).
//
//  Data layer only: no views, no view model, no SQLite. The public surface is
//  an `ObservableObject` singleton that any SwiftUI view can observe with
//  `@ObservedObject private var pins = PinnedMessagesStore.shared`.
//
//  ─── Relationship to ChatFavoritesStore (deliberate mirror) ────────────────
//  Same storage decision, same threading contract, same defensive decode:
//  * A pin carries the full message body, so the store grows with the user's
//    content — JSON in Application Support, NOT UserDefaults (which is for
//    small preferences and rewrites the whole plist on every write).
//  * `PinnedMessage` stores only `String` / `Date`, so it cannot be broken by a
//    refactor of the chat model layer and the persisted JSON stays readable
//    across schema churn. Bridging from the live `ChatMessage` is left to the
//    caller (see the note at the bottom).
//  * `pinned` is main-thread affine: every entry point mutates the in-memory
//    array synchronously (a read right after a write is never stale) and then
//    enqueues one atomic disk replace on a serial utility queue.
//
//  ─── Identity ──────────────────────────────────────────────────────────────
//  `messageId` is a `String`, so the store can key off whatever stable id the
//  chat layer exposes (`ChatMessage.id` is a UUID — pass `id.uuidString`).
//  One pin per message id; the model's `id` is the message id.
//
//  iOS 16 compatible: this file is pure Foundation + Combine, no SwiftUI, so it
//  is unaffected by the single-parameter `onChange` constraint.
//

import Combine
import Foundation

// MARK: - Model

/// One pinned message: a SNAPSHOT of the message taken when the user pinned it.
///
/// Snapshot, not a live reference, on purpose: a pin must survive the session
/// (or the message) being deleted, and it must render without loading a
/// session's message table.
struct PinnedMessage: Identifiable, Codable, Hashable {

    /// Stable id of the pinned message (e.g. `ChatMessage.id.uuidString`).
    let messageId: String
    /// `ChatSession.id` (verified: `Agent/Chat/ChatStore.swift` —
    /// `struct ChatSession: Identifiable, Codable, Hashable { let id: String }`).
    let sessionId: String
    /// The message body captured at pin time.
    let text: String
    /// When the user pinned it (drives ordering: newest first).
    let pinnedAt: Date

    /// `Identifiable` conformance doubles as "one pin per message".
    var id: String { messageId }

    init(messageId: String,
         sessionId: String,
         text: String,
         pinnedAt: Date = Date()) {
        self.messageId = messageId
        self.sessionId = sessionId
        self.text = text
        self.pinnedAt = pinnedAt
    }

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whitespace-collapsed, length-capped, single line for the pin bar.
    /// Returns "" for blank input (never a bare "…").
    var preview: String { PinnedMessage.oneLinePreview(of: text) }

    static func oneLinePreview(of text: String, limit: Int = 120) -> String {
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard limit > 0, collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)) + "…"
    }
}

// MARK: - Store

/// App-wide pinned-messages store.
///
/// Usage (UI):
/// ```swift
/// @ObservedObject private var pins = PinnedMessagesStore.shared
/// ...
/// if pins.isPinned(messageId: id) { … }
/// ```
final class PinnedMessagesStore: ObservableObject {

    /// Shared instance. `nonisolated(unsafe)` is the same escape hatch
    /// `ChatFavoritesStore` / `AppLogger` use: it documents that the store is
    /// deliberately not actor-isolated and keeps the declaration legal in the
    /// Swift 6 language mode. All API below is main-thread affine.
    nonisolated(unsafe) static let shared = PinnedMessagesStore()

    /// All pins, newest pin first (`pinnedAt` descending). `private(set)` —
    /// every mutation goes through a method here so the file and the published
    /// array can never drift apart.
    @Published private(set) var pinned: [PinnedMessage] = []

    /// Where the JSON lives. Injectable so tests can point at a temp file.
    let fileURL: URL

    nonisolated(unsafe) private static let logger = AppLogger(category: "PinnedMessages")

    /// Serial queue for disk writes (two saves can never interleave); `.utility`
    /// because a pin save is never urgent.
    private let ioQueue = DispatchQueue(label: "com.cuicsi.minisvps.pinned-messages.io",
                                        qos: .utility)

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? PinnedMessagesStore.defaultFileURL()
        self.pinned = PinnedMessagesStore.read(from: self.fileURL)
    }

    // MARK: Queries

    var isEmpty: Bool { pinned.isEmpty }
    var count: Int { pinned.count }

    /// 查询某条消息是否已固定. O(n) over the pin list — hundreds of rows at most.
    func isPinned(messageId: String) -> Bool {
        pinned.contains { $0.messageId == messageId }
    }

    func pinnedMessage(withId messageId: String) -> PinnedMessage? {
        pinned.first { $0.messageId == messageId }
    }

    /// One conversation's pins, newest first.
    func pinned(inSession sessionId: String) -> [PinnedMessage] {
        pinned.filter { $0.sessionId == sessionId }
    }

    // MARK: Mutations

    /// 固定一条消息. Re-pinning an already-pinned message is idempotent and
    /// refreshes the stored text (keeps the id and the original `pinnedAt`).
    @discardableResult
    func pin(messageId: String,
             sessionId: String,
             text: String,
             pinnedAt: Date = Date()) -> PinnedMessage {
        let entry = PinnedMessage(messageId: messageId,
                                  sessionId: sessionId,
                                  text: text,
                                  pinnedAt: pinnedAt)
        upsert(entry)
        return entry
    }

    /// 取消固定. Returns true when a row was removed.
    @discardableResult
    func unpin(messageId: String) -> Bool {
        guard isPinned(messageId: messageId) else { return false }
        pinned = pinned.filter { $0.messageId != messageId }
        persist()
        return true
    }

    /// 固定/取消固定. Returns the resulting state: `true` = now pinned.
    @discardableResult
    func toggle(messageId: String, sessionId: String, text: String) -> Bool {
        if isPinned(messageId: messageId) {
            unpin(messageId: messageId)
            return false
        }
        pin(messageId: messageId, sessionId: sessionId, text: text)
        return true
    }

    /// Drop a whole conversation's pins (call when the session is deleted).
    /// Returns how many rows went away.
    @discardableResult
    func removeAll(inSession sessionId: String) -> Int {
        let before = pinned.count
        pinned = pinned.filter { $0.sessionId != sessionId }
        let removed = before - pinned.count
        if removed > 0 { persist() }
        return removed
    }

    /// 删除全部固定. Returns how many rows went away.
    @discardableResult
    func removeAll() -> Int {
        let removed = pinned.count
        guard removed > 0 else { return 0 }
        pinned = []
        persist()
        return removed
    }

    // MARK: Persistence

    /// Re-read the JSON file, discarding unsaved in-memory state.
    func reload() {
        pinned = PinnedMessagesStore.read(from: fileURL)
    }

    /// Block until every enqueued disk write has finished. Diagnostic / test
    /// helper — the UI never needs it.
    func flushPendingWrites() {
        ioQueue.sync {}
    }

    private func upsert(_ entry: PinnedMessage) {
        var next = pinned
        if let index = next.firstIndex(where: { $0.messageId == entry.messageId }) {
            // Refresh the body but keep the original pin time (stable order).
            let original = next[index]
            next[index] = PinnedMessage(messageId: original.messageId,
                                        sessionId: entry.sessionId,
                                        text: entry.text,
                                        pinnedAt: original.pinnedAt)
        } else {
            next.append(entry)
        }
        next.sort { $0.pinnedAt > $1.pinnedAt }
        pinned = next
        persist()
    }

    /// Encode on the caller's thread, then write atomically off-thread. The
    /// snapshot is taken here, so a later mutation cannot race the write.
    private func persist() {
        let snapshot = pinned
        let url = fileURL
        let data: Data
        do {
            data = try PinnedMessagesStore.makeEncoder().encode(snapshot)
        } catch {
            PinnedMessagesStore.logger.error("[PinnedMessages] encode failed: \(error.localizedDescription)")
            return
        }
        ioQueue.async {
            do {
                try data.write(to: url, options: [.atomic])
            } catch {
                PinnedMessagesStore.logger.error("[PinnedMessages] write failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Storage plumbing

    /// `<Application Support>/ChatPinnedMessages/pinned.json`.
    static func defaultFileURL() -> URL {
        let fm = FileManager.default
        let base: URL
        if let appSupport = try? fm.url(for: .applicationSupportDirectory,
                                        in: .userDomainMask,
                                        appropriateFor: nil,
                                        create: true) {
            base = appSupport
        } else {
            base = fm.temporaryDirectory
        }
        let directory = base.appendingPathComponent("ChatPinnedMessages", isDirectory: true)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("pinned.json", isDirectory: false)
    }

    /// A fresh encoder/decoder per call: saves are rare and this keeps the type
    /// free of a shared, non-Sendable JSONEncoder instance.
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
    private static func read(from url: URL) -> [PinnedMessage] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            let rows = try makeDecoder().decode([PinnedMessage].self, from: data)
            return sanitize(rows)
        } catch {
            logger.error("[PinnedMessages] load failed at \(url.path): \(error.localizedDescription)")
            quarantineCorruptFile(at: url)
            return []
        }
    }

    /// Newest first, one row per message id (defensive: a hand-edited or
    /// partially-written file cannot produce duplicate rows).
    private static func sanitize(_ rows: [PinnedMessage]) -> [PinnedMessage] {
        var seen = Set<String>()
        var out: [PinnedMessage] = []
        for row in rows.sorted(by: { $0.pinnedAt > $1.pinnedAt }) {
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

// MARK: - Note for callers (no bridge here on purpose)
//
// This file intentionally references NO project type except `AppLogger`, so it
// cannot drift. To pin a live `ChatMessage` the caller supplies the id string
// and the captured body itself, e.g.:
//
//   let text = message.content
//   PinnedMessagesStore.shared.pin(messageId: message.id.uuidString,
//                                  sessionId: session.id,
//                                  text: text)
//
// (`ChatMessage.id` is a `UUID` and `ChatSession.id` is a `String`, both read
// out of `Agent/Chat/ChatModels.swift` / `Agent/Chat/ChatStore.swift` before
// being referenced in this comment.)
