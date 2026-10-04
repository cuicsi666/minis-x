//
//  ExportShareSheet.swift
//  MinisApp
//
//  Minis_X feature #4 (UI) — 会话导出为 Markdown 的预览 + 分享面板.
//
//  Presentation for `ConversationExporter`. The exporter is a pure formatting
//  layer that already knows how to render the document and drop it in a temp
//  file; this file adds the two things it deliberately leaves out: a preview
//  of the exact bytes that will be shared, and the activity sheet itself.
//
//      ExportShareSheet(title: session.title, messages: snapshot)
//
//  ─── Contract with ConversationExporter (read, not guessed) ─────────────────
//    ExportedMessage(role: String, text: String, date: Date? = nil)
//      (also ExportedMessage(role: Role, …) with Role: user/assistant/system/tool)
//    ConversationExporter.markdown(title:messages:exportedAt:options:) -> String
//    ConversationExporter.writeToTemporaryFile(title:messages:exportedAt:
//                                              options:fileName:) throws -> URL
//    ConversationExportError.writeFailed(String)   // LocalizedError
//    MarkdownExportOptions()  // skipEmptyMessages = true by default
//
//  ─── Why the preview reads the written file back ────────────────────────────
//  The preview renders `String(contentsOf: url)`, i.e. the file the share sheet
//  will actually hand out. Rendering `markdown(...)` separately would be one
//  extra call that can silently diverge from the written file (encoding
//  fallback, a sanitised title, a future writer change). The in-memory render
//  is kept only as the fallback for the pathological "written but unreadable"
//  case.
//
//  ─── Why the activity-sheet wrapper is NESTED (read this before renaming) ───
//  This file deliberately does NOT declare a top-level `ShareSheet`. The app
//  target already has one: `ContentView.swift:6633 private struct ShareSheet`
//  (the single-URL variant). Swift's redeclaration checker compares top-level
//  declarations ACROSS FILES and only skips a candidate when it is inaccessible
//  from the other file (`!other->isAccessibleFrom(currentDC) -> continue` in
//  TypeCheckDeclPrimary.cpp's CheckRedeclarationRequest). A file-private
//  declaration is therefore skipped when checked from here — but this file's
//  INTERNAL declaration is visible from ContentView.swift, so the pair is
//  exactly the shape that can diagnose "invalid redeclaration of 'ShareSheet'"
//  inside ContentView.swift, a file this feature is not allowed to touch.
//  Nesting the wrapper removes the module-level name entirely: ContentView's
//  file-private type keeps working unchanged, and inside this file the call
//  site still reads `ShareSheet(activityItems: […])`.
//  Fully qualified from outside: `ExportShareSheet.ShareSheet`.
//

import SwiftUI
import UIKit

@MainActor
struct ExportShareSheet: View {

    /// `UIActivityViewController` in SwiftUI form, for any mix of activity
    /// items (here: the exported `.md` file URL).
    ///
    /// Nested on purpose — see the file header.
    struct ShareSheet: UIViewControllerRepresentable {

        let activityItems: [Any]

        init(activityItems: [Any]) {
            self.activityItems = activityItems
        }

        func makeUIViewController(context: Context) -> UIActivityViewController {
            UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        }

        func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
    }

    private let title: String?
    private let messages: [ExportedMessage]

    @Environment(\.dismiss) private var dismiss

    /// The document exactly as written to disk (see the file header).
    @State private var markdown = ""
    /// The temp file handed to `ShareSheet`. Non-nil == the share button is live.
    @State private var fileURL: URL?
    @State private var errorMessage: String?
    @State private var isPreparing = false
    @State private var showShareSheet = false

    init(title: String?, messages: [ExportedMessage]) {
        self.title = title
        self.messages = messages
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            Group {
                if let errorMessage {
                    errorState(errorMessage)
                } else if markdown.isEmpty {
                    loadingState
                } else {
                    preview
                }
            }
            .navigationTitle("导出预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showShareSheet = true
                    } label: {
                        Label("分享", systemImage: "square.and.arrow.up")
                    }
                    .disabled(fileURL == nil)
                }
            }
            .sheet(isPresented: $showShareSheet) {
                if let url = fileURL {
                    ShareSheet(activityItems: [url])
                }
            }
        }
        .task { prepare() }
    }

    // MARK: Preview

    private var preview: some View {
        VStack(spacing: 0) {
            ScrollView {
                Text(markdown)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(16)
            }

            if let fileURL {
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "doc.text")
                    Text(fileURL.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text("\(exportedMessageCount) 条消息")
                        .lineLimit(1)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(Color(uiColor: .secondarySystemBackground))
            }
        }
    }

    /// Mirrors `MarkdownExportOptions.skipEmptyMessages` (true by default), so
    /// the footer counts what the document actually contains rather than
    /// including tool-only turns the exporter drops.
    private var exportedMessageCount: Int {
        messages.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
    }

    // MARK: States

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("正在生成 Markdown 预览…")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34))
                .foregroundStyle(.orange)
            Text("导出失败")
                .font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("重试") { prepare() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    // MARK: Export

    private func prepare() {
        guard !isPreparing else { return }
        isPreparing = true
        errorMessage = nil

        do {
            let url = try ConversationExporter.writeToTemporaryFile(title: title,
                                                                    messages: messages)
            fileURL = url
            markdown = (try? String(contentsOf: url, encoding: .utf8))
                ?? ConversationExporter.markdown(title: title, messages: messages)
        } catch {
            fileURL = nil
            markdown = ""
            errorMessage = error.localizedDescription
        }

        isPreparing = false
    }
}
