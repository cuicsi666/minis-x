//
//  DaySeparatorBuilder.swift
//  Minis
//
//  功能：聊天日期分隔线 —— 纯 Foundation 计算工具（零 UI 依赖，可单测）。
//
//  设计约束（本文件新增，不修改任何既有文件）：
//  * 仅依赖 Foundation，不 import SwiftUI / UIKit。
//  * 所有日期计算走 `Calendar`，所有字符串输出走 `DateFormatter`，
//    locale 固定 `zh_CN`，与设备语言/区域解耦。
//  * iOS 16 兼容：不依赖任何 iOS 17+ API。
//

import Foundation

// MARK: - 分隔线信息

/// 一条需要插入到消息列表中的日期分隔线。
///
/// - `messageIndex`：分隔线应插入到 `dates[messageIndex]` **之前**。
/// - `label`：中文文案，例如「今天」「昨天」「2026年10月3日 周五」。
struct DaySeparatorInfo: Sendable {
    /// 分隔线应插入到该下标的消息之前。
    let messageIndex: Int
    /// 展示文案（今天 / 昨天 / 2026年10月3日 周五）。
    let label: String
}

// MARK: - 构建器

/// 根据消息时间序列计算需要插入的日期分隔线（无状态命名空间）。
enum DaySeparatorBuilder {

    // MARK: Locale / Calendar

    /// 需求指定：固定简体中文 locale，不受设备语言/区域影响
    /// （例如 12 小时制 region 也必须输出 24 小时制的日期文案）。
    private static let zhLocale = Locale(identifier: "zh_CN")

    /// 按本地日历日切分「今天 / 昨天」，必须带 locale，
    /// 否则不同 region 的历法/周首日会影响日期差计算。
    private static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.locale = zhLocale
        return c
    }()

    // DateFormatter 是引用类型且未标注 Sendable；本项目主 target 使用
    // Swift 6 语言模式，非隔离的 `static let` 会被判定为「不并发安全」。
    // 这里只做只读格式化（DateFormatter 的格式化调用本身线程安全），
    // 用 `nonisolated(unsafe)` 显式声明，避免每次调用重复构造 formatter。

    /// 完整日期 + 星期，例如「2026年10月3日 周五」。
    nonisolated(unsafe) private static let fullDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = zhLocale
        // zh_CN 下 "EEE" → 「周五」（"EEEE" 会得到「星期五」）。
        f.dateFormat = "yyyy年M月d日 EEE"
        return f
    }()

    // MARK: 公开 API

    /// 计算需要插入的日期分隔线。
    ///
    /// 规则：
    /// * 列表第一条消息前始终插入一条分隔线（下标 0）。
    /// * 之后每当相邻两条消息**不在同一日历日**时，在其前插入一条。
    ///
    /// - Parameters:
    ///   - dates: 按列表顺序排列的消息时间（应为非递减；乱序时以相邻比较为准）。
    ///   - now: 参照「现在」，用于判定今天/昨天，便于测试注入。
    /// - Returns: 按下标升序排列的 `DaySeparatorInfo`；`dates` 为空时返回 `[]`。
    static func separators(for dates: [Date], now: Date = Date()) -> [DaySeparatorInfo] {
        guard !dates.isEmpty else { return [] }

        var result: [DaySeparatorInfo] = []
        result.reserveCapacity(dates.count)

        // 第一条消息前始终插入分隔线。
        result.append(DaySeparatorInfo(messageIndex: 0, label: label(for: dates[0], now: now)))

        guard dates.count > 1 else { return result }

        for index in 1..<dates.count where !isSameDay(dates[index], dates[index - 1]) {
            result.append(
                DaySeparatorInfo(messageIndex: index, label: label(for: dates[index], now: now))
            )
        }
        return result
    }

    /// 单个日期对应的分隔线文案。
    ///
    /// - 今天 → `今天`
    /// - 昨天 → `昨天`
    /// - 其它（含未来时间）→ `2026年10月3日 周五`
    static func label(for date: Date, now: Date = Date()) -> String {
        if isSameDay(date, now) { return "今天" }
        if let days = dayDelta(from: date, to: now), days == 1 { return "昨天" }
        return fullDateFormatter.string(from: date)
    }

    /// 两个时间是否落在同一「日历日」（按 zh_CN 公历）。
    static func isSameDay(_ a: Date, _ b: Date) -> Bool {
        calendar.isDate(a, inSameDayAs: b)
    }

    // MARK: 内部

    /// `date` 到 `now` 相隔的日历天数（`now` 更新 → 结果为正）。
    private static func dayDelta(from date: Date, to now: Date) -> Int? {
        calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: now)
        ).day
    }
}
