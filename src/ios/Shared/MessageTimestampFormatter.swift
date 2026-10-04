//
//  MessageTimestampFormatter.swift
//  Minis
//
//  功能 #2：消息时间戳 —— 纯格式化工具 + 显示设置。
//
//  设计约束（本文件新增，不修改任何既有文件）：
//  * 仅依赖 Foundation / Combine，零 UI 依赖（不 import SwiftUI / UIKit）。
//  * 所有时间计算走 `Calendar`，所有字符串输出走 `DateFormatter`，
//    locale 固定 `Locale(identifier: "zh_CN")`，与设备 region 解耦。
//

import Combine
import Foundation

// MARK: - 展示风格

/// 消息时间戳的展示风格。
///
/// - `smart`    智能：今天只显示时分，昨天带「昨天」，一周内带星期，更早显示完整日期。
/// - `absolute` 绝对：始终 `yyyy-MM-dd HH:mm`。
/// - `relative` 相对：`3 分钟前` / `2 小时前` / `昨天` / `5 天前`。
enum TimestampStyle: String, CaseIterable, Identifiable {
    case smart
    case absolute
    case relative

    var id: String { rawValue }

    /// 中文名（设置页 Picker 可直接使用）。
    var displayName: String {
        switch self {
        case .smart:    return "智能"
        case .absolute: return "绝对"
        case .relative: return "相对"
        }
    }
}

// MARK: - 格式化器

/// 消息时间戳格式化工具（无状态命名空间）。
enum MessageTimestampFormatter {

    // MARK: Locale / Calendar

    /// 需求指定：固定简体中文 locale，不受设备语言/区域影响
    /// （例如 12 小时制 region 也必须输出 24 小时制 `HH:mm`）。
    private static let zhLocale = Locale(identifier: "zh_CN")

    /// 按本地日历日切分「今天 / 昨天 / 一周内」，必须带 locale，
    /// 否则不同 region 的「一周的第一天」/ 历法会影响日期差。
    private static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.locale = zhLocale
        return c
    }()

    // DateFormatter 是引用类型且未标注 Sendable。本项目主 target 使用
    // Swift 6 语言模式，非隔离的 `static let` 会被判定为「不并发安全」。
    // 这里只做只读格式化（DateFormatter 的格式化调用本身线程安全），
    // 用 `nonisolated(unsafe)` 显式声明，避免每次调用都重新构造 formatter
    // ——聊天列表滚动时同一帧可能触发多次。

    nonisolated(unsafe) private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = zhLocale
        f.dateFormat = "HH:mm"
        return f
    }()

    nonisolated(unsafe) private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = zhLocale
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    nonisolated(unsafe) private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = zhLocale
        // zh_CN 下 "EEE" → 「周三」（"EEEE" 会得到「星期三」）。
        f.dateFormat = "EEE"
        return f
    }()

    // MARK: 公开 API

    /// 智能格式。
    ///
    /// - 今天   → `HH:mm`            （例：`14:23`）
    /// - 昨天   → `昨天 HH:mm`        （例：`昨天 14:23`）
    /// - 一周内 → `周三 HH:mm`        （例：`周三 14:23`）
    /// - 更早   → `yyyy-MM-dd HH:mm` （例：`2026-09-28 14:23`）
    ///
    /// 未来时间（时钟漂移 / 跨设备同步）退回绝对格式，绝不输出负数天。
    static func smart(_ date: Date, now: Date = Date()) -> String {
        let time = timeFormatter.string(from: date)

        if calendar.isDate(date, inSameDayAs: now) {
            return time
        }

        guard let days = dayDelta(from: date, to: now), days > 0 else {
            return dateTimeFormatter.string(from: date)
        }

        if days == 1 { return "昨天 " + time }
        if days < 7  { return weekdayFormatter.string(from: date) + " " + time }
        return dateTimeFormatter.string(from: date)
    }

    /// 绝对格式：`yyyy-MM-dd HH:mm`。
    static func absolute(_ date: Date) -> String {
        dateTimeFormatter.string(from: date)
    }

    /// 相对格式。
    ///
    /// - < 1 分钟 → `刚刚`
    /// - < 1 小时 → `3 分钟前`
    /// - < 24 小时 → `2 小时前`
    /// - 昨天（按日历日）→ `昨天`
    /// - 更早 → `5 天前`
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "刚刚" }

        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) 分钟前" }

        let hours = Int(seconds / 3600)
        if hours < 24 { return "\(hours) 小时前" }

        guard let days = dayDelta(from: date, to: now), days > 0 else {
            return dateTimeFormatter.string(from: date)
        }
        if days == 1 { return "昨天" }
        return "\(days) 天前"
    }

    /// 按风格分发（UI 侧一行调用，免去各处 switch）。
    static func format(_ date: Date, style: TimestampStyle, now: Date = Date()) -> String {
        switch style {
        case .smart:    return smart(date, now: now)
        case .absolute: return absolute(date)
        case .relative: return relative(date, now: now)
        }
    }

    // MARK: 内部

    /// 相隔的日历天数（按本地日历日切分；`now` 更新 → 结果为正）。
    private static func dayDelta(from date: Date, to now: Date) -> Int? {
        calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: now)
        ).day
    }
}

// MARK: - 显示设置

/// 消息时间戳的显示设置（单例，UserDefaults 持久化）。
///
/// `@MainActor` 与项目内既有的 `FontSettings.shared` 保持一致：Swift 6 语言
/// 模式下，非 Sendable 类型的非隔离 `static let shared` 属于不并发安全，
/// 需要全局 actor 隔离。UI 层的读写都在主线程，不受影响。
@MainActor
final class TimestampDisplaySettings: ObservableObject {

    static let shared = TimestampDisplaySettings()

    private enum Keys {
        /// 需求指定的 key：未写入过时默认 `true`（开启）。
        static let enabled = "MinisX.showMessageTimestamp"
        /// 风格 key（需求未指定，沿用同一命名空间）。
        static let style = "MinisX.messageTimestampStyle"
    }

    /// 是否在消息行显示时间戳。默认 `true`。
    @Published var enabled: Bool = true {
        didSet {
            guard enabled != oldValue else { return }
            UserDefaults.standard.set(enabled, forKey: Keys.enabled)
        }
    }

    /// 时间戳展示风格。默认 `.smart`。
    @Published var style: TimestampStyle = .smart {
        didSet {
            guard style != oldValue else { return }
            UserDefaults.standard.set(style.rawValue, forKey: Keys.style)
        }
    }

    private init() {
        let ud = UserDefaults.standard
        // 只有显式写入过才覆盖默认 true —— `bool(forKey:)` 对未写入的 key
        // 返回 false，会把「默认开启」错误地变成「默认关闭」。
        if ud.object(forKey: Keys.enabled) != nil {
            enabled = ud.bool(forKey: Keys.enabled)
        }
        if let raw = ud.string(forKey: Keys.style),
           let parsed = TimestampStyle(rawValue: raw) {
            style = parsed
        }
    }

    /// 按当前设置格式化（供 UI 直接调用）。
    func formatted(_ date: Date, now: Date = Date()) -> String {
        MessageTimestampFormatter.format(date, style: style, now: now)
    }
}
