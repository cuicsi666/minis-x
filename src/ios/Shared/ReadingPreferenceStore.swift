//
//  ReadingPreferenceStore.swift
//  Minis
//
//  功能：聊天阅读体验 —— 「字号缩放 + 行距」设置存储（单例，UserDefaults 持久化）。
//
//  与既有 `FontSettings` 的分工（不重复造轮子）：
//  * 既有 `FontSettings` 已提供**离散档位**的字号缩放：
//      - chatInputScale / messageBaseScale / appBaseScale（FontScaleLevel，6 档）
//      - 通过 `scaledMessage(_:)` 等返回已缩放的 CGFloat。
//      - 以及 App Base 的全局 DynamicTypeSize 覆盖。
//  * 本 Store **不**重复上述离散档位，而是补充两个 *正交* 的连续维度：
//      - `fontScale`：0.85–1.4 的**连续**字号缩放（相对 17pt 正文基准）。
//      - `lineSpacing`：1.0–1.8 的**行距倍数**（用于 SwiftUI `.lineSpacing()`）。
//    需要同时使用时，先按 FontSettings 得到基准字号，再乘本 store 的 fontScale 即可。
//
//  设计约束（本文件新增，不修改任何既有文件）：
//  * 仅依赖 SwiftUI + Combine + Foundation。
//  * `@MainActor`：与项目内既有的 `FontSettings.shared` / `TimestampDisplaySettings`
//    保持一致。Swift 6 语言模式下，非 Sendable 类型的非隔离 `static let shared`
//    属于不并发安全，需全局 actor 隔离；UI 层读写均在主线程。
//  * iOS 16 兼容：不使用任何 iOS 17+ API。
//

import Combine
import Foundation
import SwiftUI

/// 阅读偏好（字号 / 行距）存储。
///
/// 用法：
/// ```swift
/// let store = ReadingPreferenceStore.shared
/// Text(body).font(store.scaledBodyFont).lineSpacing(store.resolvedLineSpacing)
/// ```
@MainActor
final class ReadingPreferenceStore: ObservableObject {

    static let shared = ReadingPreferenceStore()

    // MARK: - 常量

    /// 正文基准字号（pt）。与 SwiftUI `.body` 语义字号一致。
    static let baseBodyFontSize: CGFloat = 17

    /// 字号缩放允许区间。
    static let fontScaleRange: ClosedRange<Double> = 0.85...1.4
    /// 行距倍数允许区间。
    static let lineSpacingRange: ClosedRange<Double> = 1.0...1.8

    static let defaultFontScale: Double = 1.0
    static let defaultLineSpacing: Double = 1.15

    private enum Keys {
        /// 需求指定的 key：完整字面量 "MinisX.readingFontScale"。
        static let fontScale = "MinisX.readingFontScale"
        /// 需求指定的 key：完整字面量 "MinisX.readingLineSpacing"。
        static let lineSpacing = "MinisX.readingLineSpacing"
    }

    // MARK: - Published

    /// 连续字号缩放，范围 `0.85...1.4`，默认 `1.0`。
    @Published var fontScale: Double {
        didSet {
            let clamped = Self.clamp(fontScale, to: Self.fontScaleRange)
            if clamped != fontScale {
                fontScale = clamped
            }
            // 不依赖「在 didSet 内赋值是否再次触发 didSet」的语言细节：
            // 无论是否递归，这里读到的都是已钳制后的值。
            if fontScale != oldValue {
                UserDefaults.standard.set(fontScale, forKey: Keys.fontScale)
            }
        }
    }

    /// 行距倍数，范围 `1.0...1.8`，默认 `1.15`。
    @Published var lineSpacing: Double {
        didSet {
            let clamped = Self.clamp(lineSpacing, to: Self.lineSpacingRange)
            if clamped != lineSpacing {
                lineSpacing = clamped
            }
            if lineSpacing != oldValue {
                UserDefaults.standard.set(lineSpacing, forKey: Keys.lineSpacing)
            }
        }
    }

    // MARK: - 便捷属性

    /// 已应用字号缩放的正文 `Font`（基准 `.body` = 17pt）。
    var scaledBodyFont: Font {
        .system(size: Self.baseBodyFontSize * CGFloat(fontScale))
    }

    /// 传给 SwiftUI `.lineSpacing()` 的**点数**值。
    ///
    /// `lineSpacing` 存的是「行距倍数」（1.0 = 不加额外行距）；这里换算成
    /// 额外行距的点值 = (倍数 − 1) × 当前字号，随字号缩放同步放大，保证
    /// 视觉比例稳定。结果保证 ≥ 0。
    var resolvedLineSpacing: CGFloat {
        let base = Self.baseBodyFontSize * CGFloat(fontScale)
        return max(0, (CGFloat(lineSpacing) - 1) * base)
    }

    /// 是否偏离默认值（用于设置页显示「恢复默认」）。
    var isModified: Bool {
        fontScale != Self.defaultFontScale || lineSpacing != Self.defaultLineSpacing
    }

    // MARK: - Init

    private init() {
        let ud = UserDefaults.standard
        // 未写入过 key 时 `double(forKey:)` 返回 0，会把默认值错误地变成 0；
        // 因此显式用 `object(forKey:)` 判断是否已持久化。
        if ud.object(forKey: Keys.fontScale) != nil {
            fontScale = Self.clamp(ud.double(forKey: Keys.fontScale), to: Self.fontScaleRange)
        } else {
            fontScale = Self.defaultFontScale
        }
        if ud.object(forKey: Keys.lineSpacing) != nil {
            lineSpacing = Self.clamp(ud.double(forKey: Keys.lineSpacing), to: Self.lineSpacingRange)
        } else {
            lineSpacing = Self.defaultLineSpacing
        }
    }

    // MARK: - Reset

    /// 恢复默认（字号 1.0 / 行距 1.15）。
    func resetToDefaults() {
        fontScale = Self.defaultFontScale
        lineSpacing = Self.defaultLineSpacing
    }

    // MARK: - Helpers

    private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
