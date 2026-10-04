//
//  SessionSearchService.swift
//  MinisApp
//
//  Minis_X feature #6 — 历史会话搜索 (history search with highlight ranges).
//
//  ─── What this file is ──────────────────────────────────────────────────────
//  A pure, in-memory search over a snapshot of sessions: it answers *where* a
//  keyword matched (exact ranges in the title and in each message body) and
//  returns ready-to-render context windows around every body hit.
//
//  The store already has two SQL-level searchers (`ChatStore.searchSessions`
//  and `ChatStore.searchMessages`). Both answer "does this session contain the
//  keyword" via `LIKE '%q%'`; neither can report the match's *position*, which
//  is what a highlighted title, a highlighted snippet, or an "occurrences" count
//  needs. This service is the layer that turns hits into ranges —
//    * over results already in memory (the live session list, no DB round-trip),
//    * or over the sessions a SQL prefilter selected (two-phase search),
//  and it stays Foundation-only so it is unit-testable without SQLite.
//
//  ─── Zero coupling (deliberate) ─────────────────────────────────────────────
//  `SearchableSession` stores `String` / `[String]` only and never mentions
//  `ChatSession`, `ChatMessage`, `RawMessage` or `ChatStore`. The conversion is
//  3 lines at the call site; see the integration notes shipped with this task.
//
//  ─── Offset convention (important) ──────────────────────────────────────────
//  Every range this file returns is a `Range<Int>` of **UTF-16 code units**
//  into the string it is reported against (title → the original title;
//  `SearchSnippet.matchRange` → `SearchSnippet.text`). UTF-16 is chosen because
//  it is what `NSRange`, `NSAttributedString`, `UITextView` and every UIKit
//  highlight path already speak, so a snippet feeds straight into
//  `NSRange(location:length:)` with no conversion. When a Swift
//  `Range<String.Index>` is needed instead, use ``stringRange(_:in:)``.
//

import Foundation

// MARK: - Input

/// A session projected into the minimal shape the search needs.
///
/// ``messages`` must be the *visible* text of the conversation in chronological
/// order. This service does no content cleanup — deciding what counts as
/// visible text (dropping `toolUse` / `toolResult` / `mediaRef` parts, stripping
/// `<system-reminder>` envelopes, skipping tool-result-only rows) belongs to the
/// caller, which knows the message schema.
struct SearchableSession: Sendable, Equatable {

    let id: String
    let title: String
    let messages: [String]

    /// `title` is optional purely for call-site convenience: `ChatSession.title`
    /// is `String?`, and taking it directly avoids a `?? ""` at every use.
    init(id: String, title: String? = nil, messages: [String] = []) {
        self.id = id
        self.title = title ?? ""
        self.messages = messages
    }
}

// MARK: - Output

/// One context window around one body hit.
struct SearchSnippet: Sendable, Equatable {

    /// The window's text, trimmed to whole grapheme clusters. When context had
    /// to be cut off, a `…` is prepended/appended so the reader can tell the
    /// window is not the whole message.
    let text: String
    /// Where the hit sits **inside ``text``** (UTF-16 offsets into ``text``,
    /// not into the original message) — hand this straight to
    /// ``SessionSearchService/highlightRuns(in:matchRange:)`` or to
    /// `NSRange(location:length:)`.
    let matchRange: Range<Int>
    /// Index into ``SearchableSession/messages``.
    let messageIndex: Int
    /// 1-based occurrence number of this hit inside that message.
    let hitIndex: Int
    /// `true` when ``text`` starts mid-message (context was cut on the left).
    let isTruncatedAtStart: Bool
    /// `true` when ``text`` ends mid-message.
    let isTruncatedAtEnd: Bool
}

/// The search outcome for a single session.
struct SessionSearchResult: Sendable, Equatable {

    let sessionId: String
    let title: String
    /// Hits inside the title (UTF-16 offsets into the original ``title``).
    /// Empty when the keyword only hit a message body.
    let titleRanges: [Range<Int>]
    /// Context windows around the first `maxSnippetsPerSession` body hits, in
    /// message order then hit order.
    let snippets: [SearchSnippet]
    /// Total body hits, **not** capped by `maxSnippetsPerSession`.
    let messageHitCount: Int
    /// Number of distinct messages with at least one hit.
    let matchedMessageCount: Int
    /// Ranking key used by ``SessionSearchService/search(sessions:query:options:)``.
    /// Higher sorts first. `titleMatchBonus + min(messageHitCount, 9999)`.
    let score: Int

    var titleMatched: Bool { !titleRanges.isEmpty }
    var contentMatched: Bool { messageHitCount > 0 }
    var hasAnyMatch: Bool { titleMatched || contentMatched }
}

/// A contiguous run of a string, flagged for highlighting.
///
/// This is what a UI needs to build an `AttributedString` / `NSAttributedString`
/// without the service knowing anything about styling: iterate the runs, style
/// the ones with `isMatch == true`, concatenate.
struct HighlightRun: Sendable, Equatable {
    let text: String
    let isMatch: Bool
}

/// Search knobs. All defaults are the sensible ones for a session-list search.
struct SessionSearchOptions: Sendable {

    /// `false` (default) → case-insensitive, locale-aware matching.
    var caseSensitive: Bool = false
    /// Also ignore accents (`café` matches `cafe`).
    var diacriticInsensitive: Bool = false
    var searchTitles: Bool = true
    var searchMessageBodies: Bool = true

    /// Characters of context kept before each hit (grapheme clusters).
    var contextBefore: Int = 40
    /// Characters of context kept after each hit.
    var contextAfter: Int = 60
    /// Upper bound on ``SessionSearchResult/snippets`` per session.
    /// ``SessionSearchResult/messageHitCount`` still counts every hit.
    var maxSnippetsPerSession: Int = 3
    /// Hard cap on returned sessions. `<= 0` means unlimited.
    var maxResults: Int = 100
    /// Drop sessions with no hit. `false` returns every input session, so a
    /// caller can render "no results" rows from the same list.
    var returnsOnlyMatches: Bool = true
    /// Added to a session's score when the title matched, so title hits rank
    /// above body-only hits regardless of body hit count.
    var titleMatchBonus: Int = 10_000
}

// MARK: - Service

/// Stateless session search. Caseless enum: nothing to instantiate, every entry
/// point is a static function over value types, so it is safe to call from any
/// thread/actor without synchronisation.
enum SessionSearchService {

    // MARK: Entry points

    /// Search many sessions.
    ///
    /// - Parameter query: the keyword. Matched as a whole phrase (internal
    ///   spaces are significant); surrounding whitespace is ignored. A blank
    ///   query returns `[]`.
    /// - Returns: matched sessions, best first: title hits before body-only
    ///   hits, then by body hit count, ties in input order (stable).
    static func search(sessions: [SearchableSession],
                       query: String,
                       options: SessionSearchOptions = SessionSearchOptions()) -> [SessionSearchResult] {
        let needle = normalizedQuery(query)
        guard let needle else { return [] }

        var ranked: [(index: Int, result: SessionSearchResult)] = []
        for (index, session) in sessions.enumerated() {
            if let result = evaluate(session, needle: needle, options: options) {
                ranked.append((index, result))
            }
        }

        // Explicit tie-break on input index: `sort` is not guaranteed stable,
        // and the sidebar expects input order for equally-scored sessions.
        ranked.sort { lhs, rhs in
            if lhs.result.score != rhs.result.score { return lhs.result.score > rhs.result.score }
            return lhs.index < rhs.index
        }

        if options.maxResults > 0, ranked.count > options.maxResults {
            ranked = Array(ranked.prefix(options.maxResults))
        }
        return ranked.map { $0.result }
    }

    /// Search one session.
    /// - Returns: `nil` when the session does not match (or when
    ///   `options.returnsOnlyMatches` is `false` **and** nothing matched, since
    ///   a result carrying no hit has no reason to exist).
    static func search(session: SearchableSession,
                       query: String,
                       options: SessionSearchOptions = SessionSearchOptions()) -> SessionSearchResult? {
        guard let needle = normalizedQuery(query) else { return nil }
        return evaluate(session, needle: needle, options: options)
    }

    // MARK: Primitives

    /// All occurrences of `query` in `text`, as UTF-16 offsets into `text`
    /// (ascending, non-overlapping). Empty when the query is blank.
    ///
    /// Case-insensitive by default and locale-aware: the scanner asks
    /// `String.range(of:options:)` for the hit and then converts that
    /// `Range<String.Index>` back through `NSRange(_:in:)`, so the offsets are
    /// always valid even for Unicode case-foldings that change length
    /// (`ß` ↔ `SS`) — comparing lowercased copies and reusing their offsets
    /// would silently mis-highlight those.
    static func matchRanges(of query: String,
                            in text: String,
                            caseSensitive: Bool = false,
                            diacriticInsensitive: Bool = false) -> [Range<Int>] {
        guard let needle = normalizedQuery(query), !text.isEmpty else { return [] }

        var compareOptions: String.CompareOptions = []
        if !caseSensitive { compareOptions.insert(.caseInsensitive) }
        if diacriticInsensitive { compareOptions.insert(.diacriticInsensitive) }

        var ranges: [Range<Int>] = []
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let found = text.range(of: needle,
                                     options: compareOptions,
                                     range: searchStart..<text.endIndex) {
            let ns = NSRange(found, in: text)
            if ns.location != NSNotFound, ns.length > 0 {
                ranges.append(ns.location..<(ns.location + ns.length))
            }
            // Guaranteed to advance for a non-empty needle, but guarded anyway:
            // a pathological locale match returning an empty range must not
            // spin this loop forever.
            if found.upperBound > found.lowerBound {
                searchStart = found.upperBound
            } else {
                searchStart = text.index(after: found.lowerBound)
            }
        }
        return ranges
    }

    /// Build the context window around one hit.
    ///
    /// - Parameters:
    ///   - matchRange: UTF-16 offsets into `text` (as returned by ``matchRanges(of:in:caseSensitive:diacriticInsensitive:)``).
    ///   - contextBefore/contextAfter: characters of context, clamped at the
    ///     string's ends (never negative).
    /// - Returns: a window whose ``SearchSnippet/matchRange`` is re-based into
    ///   the window's own coordinates.
    static func snippet(in text: String,
                        matchRange: Range<Int>,
                        messageIndex: Int = 0,
                        hitIndex: Int = 1,
                        contextBefore: Int = 40,
                        contextAfter: Int = 60) -> SearchSnippet {
        let ns = NSRange(location: matchRange.lowerBound, length: matchRange.count)
        guard ns.location >= 0, ns.length > 0, let hit = Range(ns, in: text) else {
            // Defensive: offsets that do not map onto `text` (stale range, or a
            // range computed against a different string). Degrade to "no
            // highlight" rather than trapping in `index(_:offsetBy:)`.
            return SearchSnippet(text: text,
                                 matchRange: 0..<0,
                                 messageIndex: messageIndex,
                                 hitIndex: hitIndex,
                                 isTruncatedAtStart: false,
                                 isTruncatedAtEnd: false)
        }

        let before = max(0, contextBefore)
        let after = max(0, contextAfter)
        let windowStart = text.index(hit.lowerBound, offsetBy: -before, limitedBy: text.startIndex) ?? text.startIndex
        let windowEnd = text.index(hit.upperBound, offsetBy: after, limitedBy: text.endIndex) ?? text.endIndex

        let truncatedAtStart = windowStart != text.startIndex
        let truncatedAtEnd = windowEnd != text.endIndex

        var window = String(text[windowStart..<windowEnd])
        if truncatedAtStart { window = "…" + window }
        if truncatedAtEnd { window += "…" }

        // Re-base the hit through Character offsets so the added "…" markers
        // (which are 1 UTF-16 unit each, but a counter-example to "assume 1
        // byte") are accounted for without arithmetic assumptions.
        let leadingMarkers = truncatedAtStart ? 1 : 0
        let characterOffset = leadingMarkers + text.distance(from: windowStart, to: hit.lowerBound)
        let characterLength = text.distance(from: hit.lowerBound, to: hit.upperBound)
        let localStart = window.index(window.startIndex, offsetBy: characterOffset)
        let localEnd = window.index(localStart, offsetBy: characterLength)
        let localNS = NSRange(localStart..<localEnd, in: window)

        return SearchSnippet(text: window,
                             matchRange: localNS.location..<(localNS.location + localNS.length),
                             messageIndex: messageIndex,
                             hitIndex: hitIndex,
                             isTruncatedAtStart: truncatedAtStart,
                             isTruncatedAtEnd: truncatedAtEnd)
    }

    /// Split `text` into alternating plain / matched runs for highlighting.
    ///
    /// - Parameter matchRanges: UTF-16 offsets into `text`, ascending and
    ///   non-overlapping (exactly what ``matchRanges(of:in:caseSensitive:diacriticInsensitive:)``
    ///   produces). Unsorted or overlapping input is tolerated — later ranges
    ///   that fall inside an already-emitted run are skipped — but the output is
    ///   then lossy, so sort/merge first if the input did not come from there.
    /// - Returns: one or more runs whose `text` concatenates back to `text`.
    static func highlightRuns(in text: String, matchRanges: [Range<Int>]) -> [HighlightRun] {
        guard !text.isEmpty else { return [] }
        guard !matchRanges.isEmpty else { return [HighlightRun(text: text, isMatch: false)] }

        var runs: [HighlightRun] = []
        var cursor = text.startIndex
        for range in matchRanges {
            let ns = NSRange(location: range.lowerBound, length: range.count)
            guard ns.length > 0,
                  let hit = Range(ns, in: text),
                  hit.lowerBound >= cursor,
                  hit.upperBound <= text.endIndex else { continue }
            if cursor < hit.lowerBound {
                runs.append(HighlightRun(text: String(text[cursor..<hit.lowerBound]), isMatch: false))
            }
            runs.append(HighlightRun(text: String(text[hit.lowerBound..<hit.upperBound]), isMatch: true))
            cursor = hit.upperBound
        }
        if cursor < text.endIndex {
            runs.append(HighlightRun(text: String(text[cursor...]), isMatch: false))
        }
        return runs
    }

    /// Convenience for the common single-hit case (e.g. a title with one hit,
    /// or a ``SearchSnippet``).
    static func highlightRuns(in text: String, matchRange: Range<Int>) -> [HighlightRun] {
        highlightRuns(in: text, matchRanges: [matchRange])
    }

    /// UTF-16 offset pair → `NSRange`, ready for `UITextView` /
    /// `NSAttributedString` highlighting.
    static func nsRange(_ utf16Range: Range<Int>) -> NSRange {
        NSRange(location: utf16Range.lowerBound, length: utf16Range.count)
    }

    /// UTF-16 offset pair → `Range<String.Index>` into `text`.
    /// `nil` when the offsets do not map onto `text`.
    static func stringRange(_ utf16Range: Range<Int>, in text: String) -> Range<String.Index>? {
        Range(nsRange(utf16Range), in: text)
    }

    /// Trimmed query, or `nil` when it is empty after trimming. A query of only
    /// whitespace is "no query", not "match every space".
    static func normalizedQuery(_ query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: Internals

    /// Score a result and drop non-matches. `needle` must be pre-normalised.
    private static func evaluate(_ session: SearchableSession,
                                 needle: String,
                                 options: SessionSearchOptions) -> SessionSearchResult? {
        let titleRanges = options.searchTitles
            ? matchRanges(of: needle,
                          in: session.title,
                          caseSensitive: options.caseSensitive,
                          diacriticInsensitive: options.diacriticInsensitive)
            : []

        var snippets: [SearchSnippet] = []
        var messageHitCount = 0
        var matchedMessageCount = 0

        if options.searchMessageBodies {
            for (messageIndex, message) in session.messages.enumerated() {
                let ranges = matchRanges(of: needle,
                                         in: message,
                                         caseSensitive: options.caseSensitive,
                                         diacriticInsensitive: options.diacriticInsensitive)
                guard !ranges.isEmpty else { continue }
                messageHitCount += ranges.count
                matchedMessageCount += 1

                // Every hit is counted above, but only the first
                // `maxSnippetsPerSession` get a context window: a single
                // message repeating the keyword 200 times must not ship 200
                // windows to the UI.
                guard snippets.count < options.maxSnippetsPerSession else { continue }
                for (hitIndex, range) in ranges.enumerated() {
                    guard snippets.count < options.maxSnippetsPerSession else { break }
                    snippets.append(snippet(in: message,
                                            matchRange: range,
                                            messageIndex: messageIndex,
                                            hitIndex: hitIndex + 1,
                                            contextBefore: options.contextBefore,
                                            contextAfter: options.contextAfter))
                }
            }
        }

        let result = SessionSearchResult(sessionId: session.id,
                                        title: session.title,
                                        titleRanges: titleRanges,
                                        snippets: snippets,
                                        messageHitCount: messageHitCount,
                                        matchedMessageCount: matchedMessageCount,
                                        score: score(titleMatched: !titleRanges.isEmpty,
                                                     messageHitCount: messageHitCount,
                                                     options: options))
        guard options.returnsOnlyMatches else { return result }
        return result.hasAnyMatch ? result : nil
    }

    private static func score(titleMatched: Bool,
                              messageHitCount: Int,
                              options: SessionSearchOptions) -> Int {
        let base = titleMatched ? options.titleMatchBonus : 0
        return base + min(messageHitCount, 9_999)
    }
}
