//
//  SessionSearchView.swift
//  MinisApp
//
//  Minis_X feature #6 (UI) — 历史会话搜索面板.
//
//  Presentation for `SessionSearchService`. The service is pure and stateless
//  (it answers "where did the keyword match" with UTF-16 ranges); this view
//  owns the three things the service deliberately does not: the query string,
//  the debounce, and the highlight rendering.
//
//      SessionSearchView(sessions: snapshot) { sessionId in … }   // 打开会话
//
//  ─── Contract with SessionSearchService (read, not guessed) ────────────────
//    SearchableSession(id: String, title: String? = nil, messages: [String] = [])
//    SessionSearchService.search(sessions:query:options:) -> [SessionSearchResult]
//    SessionSearchOptions() // caseSensitive, diacriticInsensitive, searchTitles,
//                           // searchMessageBodies, contextBefore, contextAfter,
//                           // maxSnippetsPerSession, maxResults,
//                           // returnsOnlyMatches, titleMatchBonus
//    SessionSearchResult: sessionId, title, titleRanges, snippets,
//                         messageHitCount, matchedMessageCount, score,
//                         titleMatched, contentMatched, hasAnyMatch
//    SearchSnippet: text, matchRange, messageIndex, hitIndex,
//                   isTruncatedAtStart, isTruncatedAtEnd
//    HighlightRun: text, isMatch
//    highlightRuns(in:matchRanges:) / highlightRuns(in:matchRange:)
//
//  ─── Threading ─────────────────────────────────────────────────────────────
//  The search runs OFF the main actor: the debounce `Task` inherits this
//  view's MainActor isolation, and only the `Task.detached` leaf touches the
//  service. Both inputs (`[SearchableSession]`, `SessionSearchOptions`) are
//  `Sendable`, so the snapshot is copied into locals first and the detached
//  closure never reads an isolated property. Results are assigned back on the
//  MainActor. Every in-flight search is cancelled when the query changes
//  again, so a slow keystroke can never overwrite a newer one.
//

import Foundation
import SwiftUI

@MainActor
struct SessionSearchView: View {

    private let sessions: [SearchableSession]
    private let onSelect: (String) -> Void
    private let options: SessionSearchOptions
    private let debounceInterval: Duration

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isSearchFieldFocused: Bool

    @State private var query = ""
    @State private var results: [SessionSearchResult] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?

    /// - Parameters:
    ///   - sessions: the sessions to search, already projected to visible text.
    ///   - onSelect: receives the `SearchableSession.id` of the tapped result.
    ///   - options: `SessionSearchOptions()` defaults (3 snippets per session,
    ///     title hits ranked first, matches only) unless the caller overrides.
    ///   - debounceInterval: keystroke debounce; 200 ms by default.
    init(sessions: [SearchableSession],
         onSelect: @escaping (String) -> Void,
         options: SessionSearchOptions = SessionSearchOptions(),
         debounceInterval: Duration = .milliseconds(200)) {
        self.sessions = sessions
        self.onSelect = onSelect
        self.options = options
        self.debounceInterval = debounceInterval
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchField
                Divider()
                content
            }
            .navigationTitle("搜索会话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .task {
            // One-frame-adjacent delay: focusing during the sheet transition
            // is unreliable, and this avoids DispatchQueue.main.asyncAfter,
            // whose @Sendable closure cannot touch @State under Swift 6.
            try? await Task.sleep(for: .milliseconds(250))
            isSearchFieldFocused = true
        }
        .onChange(of: query) { newValue in
            scheduleSearch(for: newValue)
        }
        .onDisappear {
            searchTask?.cancel()
        }
    }

    // MARK: Search field

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextField("搜索标题和消息内容", text: $query)
                .textFieldStyle(.plain)
                .focused($isSearchFieldFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit { scheduleSearch(for: query) }

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索内容")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            Color(uiColor: .secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if sessions.isEmpty {
            placeholder(icon: "tray",
                        title: "没有可搜索的会话",
                        message: "当前没有历史会话可供搜索。")
        } else if trimmedQuery.isEmpty {
            placeholder(icon: "magnifyingglass",
                        title: "输入关键词开始搜索",
                        message: "会话标题和消息内容都会被实时匹配。")
        } else if isSearching && results.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if results.isEmpty {
            placeholder(icon: "questionmark.circle",
                        title: "未找到结果",
                        message: "没有会话包含「\(trimmedQuery)」。")
        } else {
            resultsList
        }
    }

    private func placeholder(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private var resultsList: some View {
        List {
            Section {
                ForEach(results, id: \.sessionId) { result in
                    row(result)
                }
            } header: {
                Text(resultSummary)
            }
        }
        .listStyle(.insetGrouped)
    }

    private var resultSummary: String {
        if isSearching { return "搜索中…" }
        let hits = results.reduce(0) { $0 + $1.messageHitCount }
        return "\(results.count) 个会话 · \(hits) 处命中"
    }

    private func row(_ result: SessionSearchResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            highlighted(result.title.isEmpty ? "未命名会话" : result.title,
                        ranges: result.title.isEmpty ? [] : result.titleRanges)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(hitSummary(result))
                .font(.caption2)
                .foregroundStyle(.secondary)

            ForEach(result.snippets.indices, id: \.self) { index in
                let snippet = result.snippets[index]
                highlighted(snippet.text, ranges: [snippet.matchRange])
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { onSelect(result.sessionId) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("打开这个会话")
    }

    private func hitSummary(_ result: SessionSearchResult) -> String {
        var parts: [String] = []
        if result.titleMatched { parts.append("标题命中") }
        if result.messageHitCount > 0 {
            parts.append("\(result.messageHitCount) 处消息命中")
        }
        if result.matchedMessageCount > 1 {
            parts.append("分布在 \(result.matchedMessageCount) 条消息")
        }
        if parts.isEmpty { parts.append("匹配") }
        return parts.joined(separator: " · ")
    }

    // MARK: Highlighting

    /// Renders `text` with the matched runs bold + tinted. Built as an
    /// `AttributedString` (not `Text` concatenation) so the styling applies
    /// per run and survives the outer font modifiers below.
    private func highlighted(_ text: String, ranges: [Range<Int>]) -> Text {
        guard !ranges.isEmpty else { return Text(text) }
        let runs = SessionSearchService.highlightRuns(in: text, matchRanges: ranges)
        guard !runs.isEmpty else { return Text(text) }

        var output = AttributedString()
        for run in runs {
            var piece = AttributedString(run.text)
            if run.isMatch {
                piece.font = Font.body.bold()
                piece.foregroundColor = Color.accentColor
            }
            output.append(piece)
        }
        return Text(output)
    }

    // MARK: Debounced search

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Cancels the in-flight search and starts a new debounced one.
    private func scheduleSearch(for rawQuery: String) {
        searchTask?.cancel()

        let needle = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            results = []
            isSearching = false
            return
        }

        // Snapshot before hopping off the MainActor: neither `sessions` nor
        // `options` may be read from the detached closure.
        let sessionsSnapshot = sessions
        let optionsSnapshot = options
        let delay = debounceInterval

        isSearching = true
        searchTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }

            let found = await Task.detached(priority: .userInitiated) {
                SessionSearchService.search(sessions: sessionsSnapshot,
                                            query: needle,
                                            options: optionsSnapshot)
            }.value

            // A newer keystroke already cancelled this task: drop the stale
            // result instead of flashing an older list over the newer one.
            guard !Task.isCancelled else { return }
            results = found
            isSearching = false
        }
    }
}
