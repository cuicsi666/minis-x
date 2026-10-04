//
//  CodeCopyButton.swift
//  MinisApp
//
//  Minis_X feature — 代码块复制按钮 (one-tap "copy code" affordance).
//
//  Two small, self-contained SwiftUI pieces, no dependency on the chat model or
//  the markdown pipeline:
//
//    • `CodeCopyButton` — the icon-only button itself. Tap copies `code`
//      to `UIPasteboard.general.string`, flips its glyph to a checkmark for
//      1.5s, then back. No text label (icon-first; nothing to localize).
//
//    • `CodeBlockContainer` — a generic wrapper that lays CONTENT of your
//      choosing on a rounded, dark-mode-adaptive card, pins the copy button to
//      the top-right corner, and shows an optional language tag top-left.
//
//  ─── Why this exists next to the existing renderers ─────────────────────────
//  The chat markdown pipeline renders fenced code as a UIKit `NSTextAttachment`
//  (`CodeBlockAttachment.makeView(width:)` in `SelectableMarkdownView.swift`) and
//  has its own private copy affordance; `Views/Chat/ChatInputBar.swift` also
//  carries a `private` button of the same name. Those are file-private and
//  UIKit-bound. This file provides the reusable SWIFTUI surface (e.g. for
//  tool-detail sheets, previews, and new SwiftUI code cards) without touching
//  any existing type — the file-private names do not collide with these.
//
//  ─── iOS 16 / deployment notes ──────────────────────────────────────────────
//  Only iOS 15/16-era API is used: `@State`, `Task`-free `DispatchQueue`
//  timers, `.overlay(alignment:)`, `Color(uiColor:)`, `.foregroundStyle`.
//  Dark mode is handled automatically by the semantic system colours, so no
//  `colorScheme` branching is required.
//

import SwiftUI
import UIKit

// MARK: - Copy button

/// Icon-only clipboard button: `doc.on.doc` → `checkmark` for 1.5s → back.
///
///     CodeCopyButton(code: "print(\"hi\")")
struct CodeCopyButton: View {

    /// The exact text placed on the pasteboard on tap.
    private let code: String

    /// How long the "copied" confirmation stays up before reverting.
    private static let confirmationDuration: TimeInterval = 1.5

    @State private var copied = false
    /// Generation counter so a second tap during the 1.5s window cannot have its
    /// "copied" state cleared early by the first tap's pending reset.
    @State private var copyGeneration = 0

    init(code: String) {
        self.code = code
    }

    var body: some View {
        Button(action: copy) {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 24)
                .foregroundStyle(copied ? Color.green : Color.primary.opacity(0.55))
                .contentShape(Rectangle())
                .animation(.easeInOut(duration: 0.2), value: copied)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(copied ? "已复制" : "复制代码")
        .accessibilityAddTraits(.isButton)
    }

    private func copy() {
        guard !code.isEmpty else { return }
        UIPasteboard.general.string = code
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        copied = true
        copyGeneration += 1
        let generation = copyGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.confirmationDuration) {
            // Only the newest tap owns the reset; earlier timers are no-ops.
            guard generation == copyGeneration else { return }
            copied = false
        }
    }
}

// MARK: - Container

/// Rounded card that wraps arbitrary content, pins a `CodeCopyButton` to
/// the top-right corner, and shows an optional language tag top-left.
///
///     CodeBlockContainer(code: source, language: "swift") {
///         Text(source)
///             .font(.system(.footnote, design: .monospaced))
///             .frame(maxWidth: .infinity, alignment: .leading)
///     }
///
/// The `code` handed to the copy button is independent from the rendered
/// `content`, so a caller may show a syntax-highlighted (or truncated) body
/// while still copying the raw source.
struct CodeBlockContainer<Content: View>: View {

    /// Raw source copied to the pasteboard.
    private let code: String
    /// Optional language tag, e.g. `"swift"` / `"bash"`. `nil`/empty hides it.
    private let language: String?
    /// The rendered body (usually the (highlighted) code text).
    private let content: Content

    /// Vertical room reserved at the top so the corner button (and the language
    /// tag) never overlap the first line of the body.
    private static var headerHeight: CGFloat { 22 }

    init(code: String,
         language: String? = nil,
         @ViewBuilder content: () -> Content) {
        self.code = code
        self.language = language
        self.content = content()
    }

    private var hasLanguage: Bool {
        guard let language else { return false }
        return !language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .padding(.top, Self.headerHeight)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
            )
            .overlay(alignment: .topLeading) {
                if hasLanguage, let language {
                    Text(language.lowercased())
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 12)
                        .padding(.top, 8)
                        .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .topTrailing) {
                CodeCopyButton(code: code)
                    .padding(.trailing, 6)
                    .padding(.top, 5)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
    }
}
