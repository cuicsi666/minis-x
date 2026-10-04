//
//  ConversationExporter.swift
//  MinisApp
//
//  Minis_X feature #4 — 会话导出为 Markdown (conversation → Markdown export).
//
//  ─── What this file is ──────────────────────────────────────────────────────
//  A pure formatting layer. It takes an ordered list of (role, text, date)
//  triples and produces a Markdown document; optionally it drops that document
//  into a fresh temp directory and hands the caller the file URL, ready for
//  `UIActivityViewController(activityItems: [url], ...)`.
//
//  Output shape (the product spec):
//
//      # <会话标题>
//
//      > 导出时间：2026-10-04 21:00
//      > 消息数：12
//
//      ---
//
//      ## 用户
//
//      *2026-10-04 20:58*
//
//      正文原样，代码块原样保留
//
//      ---
//
//      ## AI
//      …
//
//  ─── Zero coupling (deliberate) ─────────────────────────────────────────────
//  `ExportedMessage` stores `String` / `Date` only and never mentions
//  `ChatMessage`, `RawMessage`, `ChatMessageRole` or `ContentPart`. That keeps
//  this file compilable on its own (Foundation only — no UIKit, no project
//  types), impossible to break when the chat model layer is refactored, and
//  unit-testable without spinning up `ChatStore`. The conversion from the real
//  models is 3 lines at the call site; see the integration notes shipped with
//  this task.
//
//  ─── Why every formatter is created per call ────────────────────────────────
//  `DateFormatter` is not `Sendable`. A `static let` formatter would be shared
//  mutable state under the target's Swift 6 language mode (SWIFT_VERSION = 6.0
//  in project.pbxproj) and a concurrency-checking error. Exports are rare and
//  human-triggered, so building the formatter per call costs nothing real and
//  keeps the whole file free of global state.
//

import Foundation

// MARK: - Input

/// One message handed to ``ConversationExporter``.
///
/// The role is kept as a raw `String` (not an enum) so an integration never has
/// to translate a project enum into a type defined here: pass
/// `ChatMessageRole.user`'s spelling (`"user"`), a `RawMessage.role.rawValue`
/// (`"user"` / `"assistant"`), or anything else — see ``ConversationExporter/heading(for:options:)``
/// for the recognised spellings and the fallback for unknown ones.
struct ExportedMessage: Sendable, Equatable {

    /// Canonical roles. ``init(role:text:date:)`` also accepts these raw values
    /// as plain strings, so nobody is forced to import this nested type.
    enum Role: String, Sendable, CaseIterable {
        case user
        case assistant
        case system
        case tool
    }

    /// Raw role string; see ``ConversationExporter/heading(for:options:)``.
    let role: String
    /// Message body, verbatim. Markdown (including fenced code blocks) is NOT
    /// escaped — a code block in the source stays a code block in the export.
    let text: String
    /// Timestamp shown under the section heading; `nil` suppresses the stamp
    /// for this message only.
    let date: Date?

    init(role: String, text: String, date: Date? = nil) {
        self.role = role
        self.text = text
        self.date = date
    }

    init(role: Role, text: String, date: Date? = nil) {
        self.init(role: role.rawValue, text: text, date: date)
    }
}

/// Formatting knobs for the Markdown export. The defaults are the product spec
/// (`# <title>` + 导出时间, then `## 用户` / `## AI` sections); every label is
/// overridable so a localised caller can supply its own strings without this
/// file depending on `AppLocalized` / the string catalogue.
struct MarkdownExportOptions: Sendable {

    // MARK: Headings

    /// Used when the conversation has no title (`ChatSession.title == nil`).
    var titleFallback: String = "未命名会话"
    var userHeading: String = "用户"
    var assistantHeading: String = "AI"
    var systemHeading: String = "系统"
    var toolHeading: String = "工具"

    /// Label of the H1 metadata line, e.g. `> 导出时间：2026-10-04 21:00`.
    var exportedAtLabel: String = "导出时间"
    /// Label of the H1 metadata line counting the messages actually written.
    var messageCountLabel: String = "消息数"

    // MARK: Body

    /// `yyyy-MM-dd HH:mm` stamp under the H1 and under every section heading
    /// that has a `date`.
    var includeExportMetadata: Bool = true
    var includeTimestamps: Bool = true
    /// Drop messages whose text is empty/whitespace-only (they carry nothing a
    /// Markdown reader can use; tool-only turns are all whitespace by design).
    var skipEmptyMessages: Bool = true
    /// Written in place of the body when ``skipEmptyMessages`` is `false` and
    /// the message has no text.
    var emptyMessagePlaceholder: String = "*（本条消息没有文本内容）*"
    /// `nil` = the device's current time zone.
    var timeZone: TimeZone? = nil
}

/// Failure of ``ConversationExporter/writeToTemporaryFile(title:messages:exportedAt:options:fileName:)``.
///
/// `markdown(title:messages:exportedAt:options:)` itself never throws — an
/// empty conversation simply renders a header with no sections.
enum ConversationExportError: Error, LocalizedError, Sendable {

    /// The Markdown text could not be written (directory creation or write
    /// failed). Carries the underlying `localizedDescription` because `Error`
    /// payloads must be `Sendable` and the underlying `Error` is not.
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .writeFailed(let reason):
            return "写入导出文件失败：\(reason)"
        }
    }
}

// MARK: - Exporter

/// Stateless conversation → Markdown renderer. Caseless enum: there is nothing
/// to instantiate, every entry point is a static function over value types.
enum ConversationExporter {

    /// Longest stem kept from a title before the timestamp is appended.
    private static let maxFileBaseLength = 60
    /// File-name stem used when the title is missing or sanitises away.
    private static let defaultFileBase = "Minis-Chat"

    // MARK: Markdown

    /// Render the conversation as a Markdown document.
    ///
    /// - Parameters:
    ///   - title: session title; `nil`/blank falls back to `options.titleFallback`.
    ///   - messages: chronological order. Order is preserved verbatim.
    ///   - exportedAt: stamp for the H1 metadata line (injectable for tests).
    ///   - options: see ``MarkdownExportOptions``.
    /// - Returns: the document, always terminated by exactly one `\n`.
    static func markdown(title: String?,
                         messages: [ExportedMessage],
                         exportedAt: Date = Date(),
                         options: MarkdownExportOptions = MarkdownExportOptions()) -> String {
        let timestamps = makeTimestampFormatter(options: options)

        let included = options.skipEmptyMessages
            ? messages.filter { !isBlank($0.text) }
            : messages

        var lines: [String] = []
        lines.append("# \(singleLine(title, fallback: options.titleFallback))")

        if options.includeExportMetadata {
            lines.append("")
            lines.append("> \(options.exportedAtLabel)：\(timestamps.string(from: exportedAt))")
            lines.append("> \(options.messageCountLabel)：\(included.count)")
        }

        for message in included {
            lines.append("")
            lines.append("---")
            lines.append("")
            lines.append("## \(heading(for: message.role, options: options))")
            if options.includeTimestamps, let date = message.date {
                lines.append("")
                lines.append("*\(timestamps.string(from: date))*")
            }
            lines.append("")
            // Verbatim: a fenced code block, a list, a table — all survive
            // untouched. Only surrounding blank space is trimmed, because the
            // section separators already provide it.
            let body = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append(body.isEmpty ? options.emptyMessagePlaceholder : body)
        }

        return lines.joined(separator: "\n") + "\n"
    }

    /// Render the conversation and write it to a fresh file in the temp
    /// directory. The URL is what `MinisShareSheet(url:)` /
    /// `UIActivityViewController(activityItems: [url], …)` wants.
    ///
    /// The file always lands in `tmp/minis-conversation-export-<uuid>/`: a
    /// per-export directory nothing else rewrites, so two exports of the same
    /// title never collide and a retry cannot race a previous share sheet.
    ///
    /// - Parameter fileName: explicit stem **without** extension (`.md` is
    ///   appended, and the stem is sanitised). `nil` (default) derives one from
    ///   the title plus a `yyyyMMdd-HHmmss` timestamp — see
    ///   ``suggestedFileName(title:at:)``.
    /// - Throws: ``ConversationExportError/writeFailed(_:)``.
    static func writeToTemporaryFile(title: String?,
                                     messages: [ExportedMessage],
                                     exportedAt: Date = Date(),
                                     options: MarkdownExportOptions = MarkdownExportOptions(),
                                     fileName: String? = nil) throws -> URL {
        let document = markdown(title: title,
                                messages: messages,
                                exportedAt: exportedAt,
                                options: options)
        guard let data = document.data(using: .utf8) else {
            throw ConversationExportError.writeFailed("Markdown 文本无法以 UTF-8 编码")
        }

        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("minis-conversation-export-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw ConversationExportError.writeFailed(error.localizedDescription)
        }

        let name: String
        if let requested = fileName?.trimmingCharacters(in: .whitespacesAndNewlines), !requested.isEmpty {
            name = "\(sanitizedFileBase(requested, fallback: defaultFileBase)).md"
        } else {
            name = suggestedFileName(title: title, at: exportedAt)
        }

        let url = directory.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw ConversationExportError.writeFailed(error.localizedDescription)
        }
        return url
    }

    /// `<title>-<yyyyMMdd-HHmmss>.md`, safe on every file system (no `/`, `:`,
    /// control characters, or trailing dots; capped at 60 characters + stamp).
    /// `ChatSession.title` can come from the model, so it is never trusted raw.
    static func suggestedFileName(title: String?, at date: Date = Date()) -> String {
        let base = sanitizedFileBase(title, fallback: defaultFileBase)
        return "\(base)-\(makeFileStampFormatter().string(from: date)).md"
    }

    // MARK: Role mapping

    /// Section heading for a role string.
    ///
    /// Recognised (case-insensitively, surrounding whitespace ignored):
    /// `user`/`human` → ``MarkdownExportOptions/userHeading``;
    /// `assistant`/`ai`/`bot`/`model` → ``MarkdownExportOptions/assistantHeading``;
    /// `system`/`developer` → ``MarkdownExportOptions/systemHeading``;
    /// `tool`/`tool_result`/`toolresult` → ``MarkdownExportOptions/toolHeading``.
    /// Anything else is emitted as-is on a single sanitised line, so a future
    /// role still shows up instead of silently vanishing.
    static func heading(for role: String,
                        options: MarkdownExportOptions = MarkdownExportOptions()) -> String {
        switch role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "user", "human":
            return options.userHeading
        case "assistant", "ai", "bot", "model":
            return options.assistantHeading
        case "system", "developer":
            return options.systemHeading
        case "tool", "tool_result", "toolresult":
            return options.toolHeading
        default:
            return singleLine(role, fallback: options.assistantHeading)
        }
    }

    // MARK: Helpers

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Collapse every whitespace run (including newlines) into single spaces and
    /// fall back when nothing is left. Used for text that must stay on one
    /// line — the H1 and an unknown role's heading — because a newline in a
    /// title would otherwise open a second Markdown block.
    private static func singleLine(_ raw: String?, fallback: String) -> String {
        guard let raw else { return fallback }
        let collapsed = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.isEmpty ? fallback : collapsed
    }

    /// Make a string safe to use as a file-name stem: no path separators, no
    /// characters Windows/macOS/iOS reject, no control characters, no trailing
    /// dot (which iOS silently strips), and a hard length cap.
    private static func sanitizedFileBase(_ raw: String?, fallback: String) -> String {
        guard let raw else { return fallback }
        var value = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        value = value
            .components(separatedBy: forbiddenFileNameCharacters)
            .joined(separator: "-")
        value = value
            .components(separatedBy: .controlCharacters)
            .joined(separator: "")
        if value.count > maxFileBaseLength {
            value = String(value.prefix(maxFileBaseLength))
        }
        value = value.trimmingCharacters(in: trimmableFileNameEnds)
        return value.isEmpty ? fallback : value
    }

    /// Computed, not a `static let`: `CharacterSet` is not `Sendable`, so a
    /// stored global would be rejected by the Swift 6 concurrency checker.
    private static var forbiddenFileNameCharacters: CharacterSet {
        CharacterSet(charactersIn: "/\\:*?\"<>|")
    }

    private static var trimmableFileNameEnds: CharacterSet {
        CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "."))
    }

    /// Fixed locale + fixed pattern: the default locale would render e.g. a
    /// Buddhist-era year or a 12-hour clock, so an export would not be
    /// comparable (or sortable) across devices.
    private static func makeTimestampFormatter(options: MarkdownExportOptions) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        if let timeZone = options.timeZone {
            formatter.timeZone = timeZone
        }
        return formatter
    }

    private static func makeFileStampFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }
}
