//
//  LiveTokenUsage.swift
//  Minis
//
//  Feature #7 — Live token usage.
//
//  Pure logic for the real-time token readout displayed by `LiveTokenBar`.
//  Deliberately dependency-free: Foundation only, no UIKit / SwiftUI, no
//  reference to anything else in the project, so it can be unit-tested and
//  reused from any actor.
//
//  Contents:
//    • TokenUsageEstimator  — heuristic token count for a piece of text.
//    • TokenRateTracker     — sliding-window tokens/second measurement.
//    • TokenDisplayFormatter— number → short human string.
//

import Foundation

// MARK: - TokenUsageEstimator

/// Heuristic token estimator used when the exact BPE count is not available
/// (e.g. while a reply is still streaming and has not been reported by the API).
///
/// Rules:
///   • CJK characters (Han / Kana / Hangul / CJK punctuation & full-width forms)
///     cost `cjkTokenRatio` tokens each — 1 character ≈ 0.7 token.
///   • Every other character costs `1 / charactersPerToken` tokens —
///     4 characters ≈ 1 token.
///
/// The result is rounded to the nearest token and floored at 1 for any
/// non-empty input, so `estimate("") == 0` but `estimate("a") == 1`.
public struct TokenUsageEstimator: Sendable {

    /// Tokens contributed by one CJK character. 1 CJK char ≈ 0.7 token.
    public static let defaultCJKTokenRatio: Double = 0.7

    /// Non-CJK characters that make up one token. 4 chars ≈ 1 token.
    public static let defaultCharactersPerToken: Double = 4.0

    /// Tokens per CJK character (default 0.7).
    public let cjkTokenRatio: Double

    /// Non-CJK characters per token (default 4.0).
    public let charactersPerToken: Double

    public init(cjkTokenRatio: Double = TokenUsageEstimator.defaultCJKTokenRatio,
                charactersPerToken: Double = TokenUsageEstimator.defaultCharactersPerToken) {
        // Guard against degenerate configuration — never divide by zero.
        self.cjkTokenRatio = cjkTokenRatio > 0 ? cjkTokenRatio : TokenUsageEstimator.defaultCJKTokenRatio
        self.charactersPerToken = charactersPerToken > 0 ? charactersPerToken : TokenUsageEstimator.defaultCharactersPerToken
    }

    /// Estimated token count for `text`. Returns 0 for the empty string.
    public func estimate(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }

        var cjkCount = 0
        var otherCount = 0
        for scalar in text.unicodeScalars {
            if TokenUsageEstimator.isCJK(scalar) {
                cjkCount += 1
            } else {
                otherCount += 1
            }
        }
        return estimate(cjkCharacters: cjkCount, otherCharacters: otherCount)
    }

    /// Estimated token count from pre-counted character buckets.
    ///
    /// Useful when the caller already iterates the string (or when a delta
    /// append only needs the newly appended characters counted).
    public func estimate(cjkCharacters: Int, otherCharacters: Int) -> Int {
        let cjk = Double(max(0, cjkCharacters)) * cjkTokenRatio
        let other = Double(max(0, otherCharacters)) / charactersPerToken
        let total = cjk + other
        guard total > 0 else { return 0 }
        return max(1, Int(total.rounded()))
    }

    /// Estimated token count for a delta string appended after `previousLength`
    /// characters of the same stream. Equivalent to `estimate(text) -
    /// estimate(previousText)` but computed in one pass.
    public func estimateIncrement(_ text: String, from previousLength: Int) -> Int {
        let consumed = max(0, min(previousLength, text.count))
        guard text.count > consumed else { return 0 }
        let start = text.index(text.startIndex, offsetBy: consumed)
        return estimate(String(text[start...]))
    }

    /// True for Han, Kana, Hangul, CJK punctuation and full-width forms.
    public static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x11FF,   // Hangul Jamo
             0x2E80...0x2EFF,   // CJK Radicals Supplement
             0x3000...0x303F,   // CJK Symbols and Punctuation
             0x3040...0x309F,   // Hiragana
             0x30A0...0x30FF,   // Katakana
             0x3100...0x312F,   // Bopomofo
             0x3400...0x4DBF,   // CJK Unified Ideographs Extension A
             0x4E00...0x9FFF,   // CJK Unified Ideographs
             0xA960...0xA97F,   // Hangul Jamo Extended-A
             0xAC00...0xD7AF,   // Hangul Syllables
             0xF900...0xFAFF,   // CJK Compatibility Ideographs
             0xFE30...0xFE4F,   // CJK Compatibility Forms
             0xFF00...0xFFEF,   // Halfwidth and Fullwidth Forms
             0x20000...0x2FA1F: // CJK Unified Ideographs Extension B–F
            return true
        default:
            return false
        }
    }
}

// MARK: - TokenRateTracker

/// Measures the token production rate (tokens / second) over a sliding time
/// window.
///
/// Usage:
/// ```swift
/// var tracker = TokenRateTracker(window: 5)
/// tracker.record(tokens: delta)          // called as chunks arrive
/// let rate = tracker.currentRate()       // 34.2
/// ```
///
/// The rate is the number of recorded tokens inside `window` divided by the
/// span they actually cover — *not* by the full window — so the readout ramps
/// up immediately instead of starting artificially low. The span is floored at
/// `minimumSpan` (default 1s) so a single record cannot spike the value.
public struct TokenRateTracker: Sendable {

    /// A single recorded batch of tokens.
    public struct Sample: Sendable, Equatable {
        public let timestamp: Date
        public let tokens: Int

        public init(timestamp: Date, tokens: Int) {
            self.timestamp = timestamp
            self.tokens = tokens
        }
    }

    /// Sliding window length in seconds. Samples older than this are dropped.
    public let window: TimeInterval

    /// Lower bound for the elapsed span used as the divisor, in seconds.
    /// Prevents an unbounded rate on the very first sample(s).
    public let minimumSpan: TimeInterval

    /// Clock source — injectable for deterministic tests.
    private let clock: @Sendable () -> Date

    /// Samples in ascending timestamp order.
    private var samples: [Sample] = []

    public init(window: TimeInterval = 5.0,
                minimumSpan: TimeInterval = 1.0,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.window = window > 0 ? window : 5.0
        self.minimumSpan = minimumSpan > 0 ? minimumSpan : 1.0
        self.clock = now
    }

    // MARK: Recording

    /// Records `tokens` produced right now. Non-positive values are ignored.
    /// Timestamps are taken from the tracker's clock.
    public mutating func record(tokens: Int) {
        record(tokens: tokens, at: clock())
    }

    /// Records `tokens` produced at an explicit `date` (ascending order
    /// expected). Non-positive values are ignored.
    public mutating func record(tokens: Int, at date: Date) {
        guard tokens > 0 else { return }
        samples.append(Sample(timestamp: date, tokens: tokens))
        prune(reference: date)
    }

    /// Drops samples older than the window. Called automatically by `record`;
    /// exposed for callers that want to bound memory explicitly.
    public mutating func prune(reference: Date? = nil) {
        let cutoff = (reference ?? clock()).addingTimeInterval(-window)
        if let firstLive = samples.firstIndex(where: { $0.timestamp >= cutoff }) {
            if firstLive > 0 { samples.removeFirst(firstLive) }
        } else {
            samples.removeAll(keepingCapacity: true)
        }
    }

    /// Clears all samples (e.g. when a new turn starts).
    public mutating func reset() {
        samples.removeAll(keepingCapacity: false)
    }

    // MARK: Reading

    /// Current throughput in tokens per second. Returns 0 when no samples are
    /// inside the window. Non-mutating so it can be read from `body`.
    public func currentRate() -> Double {
        currentRate(at: clock())
    }

    /// Current throughput in tokens per second as of `date`.
    public func currentRate(at date: Date) -> Double {
        let cutoff = date.addingTimeInterval(-window)
        let live = samples.filter { $0.timestamp >= cutoff }
        guard !live.isEmpty else { return 0 }

        let total = live.reduce(0) { $0 + $1.tokens }
        guard total > 0, let oldest = live.first?.timestamp else { return 0 }

        let span = date.timeIntervalSince(oldest)
        let divisor = min(window, max(span, minimumSpan))
        guard divisor > 0 else { return 0 }
        return Double(total) / divisor
    }

    /// Number of samples currently retained (after the last prune).
    public var sampleCount: Int { samples.count }

    /// Tokens summed over the retained samples. Handy for tests / debugging.
    public var recordedTokens: Int { samples.reduce(0) { $0 + $1.tokens } }

    /// True when no sample is inside the window at the current time.
    public func isEmpty() -> Bool {
        let cutoff = clock().addingTimeInterval(-window)
        return !samples.contains { $0.timestamp >= cutoff }
    }
}

// MARK: - TokenDisplayFormatter

/// Converts raw numbers into the short strings shown by `LiveTokenBar`.
///
/// ```
/// TokenDisplayFormatter.formatTokens(1200)      // "1.2k"
/// TokenDisplayFormatter.formatTokens(356)       // "356"
/// TokenDisplayFormatter.formatTokens(1_260_000) // "1.3M"
/// TokenDisplayFormatter.formatRate(34.25)       // "34.2 tok/s"
/// TokenDisplayFormatter.formatContextFraction(0.734) // "73%"
/// ```
public enum TokenDisplayFormatter {

    /// Short token count: `356`, `1.2k`, `1.3M`. Negative/zero → `"0"`.
    public static func formatTokens(_ n: Int) -> String {
        guard n > 0 else { return "0" }
        if n >= 1_000_000 {
            return String(format: "%.1fM", Double(n) / 1_000_000)
        }
        if n >= 1_000 {
            return String(format: "%.1fk", Double(n) / 1_000)
        }
        return String(n)
    }

    /// One-decimal rate string: `34.2 tok/s`. Non-finite/zero → `0.0 tok/s`.
    public static func formatRate(_ r: Double) -> String {
        guard r.isFinite, r > 0 else { return "0.0 tok/s" }
        return String(format: "%.1f tok/s", r)
    }

    /// The rate with its unit stripped: `34.2`. Used when the unit is drawn
    /// separately. Non-finite/zero → `"0.0"`.
    public static func formatRateValue(_ r: Double) -> String {
        guard r.isFinite, r > 0 else { return "0.0" }
        return String(format: "%.1f", r)
    }

    /// Context-window occupancy as a percentage: `0.734` → `"73%"`.
    /// The fraction is clamped to `0...1`; non-finite input → `"0%"`.
    public static func formatContextFraction(_ fraction: Double) -> String {
        guard fraction.isFinite else { return "0%" }
        let clamped = min(max(fraction, 0), 1)
        return "\(Int((clamped * 100).rounded()))%"
    }
}
