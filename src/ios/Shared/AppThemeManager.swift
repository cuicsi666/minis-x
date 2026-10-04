//
//  AppThemeManager.swift
//  Minis_X
//
//  功能 #8：主题配色系统
//
//  设计约束（见任务书）：
//  - 自包含、零耦合：只依赖 SwiftUI / Foundation / Combine 标准 API，
//    不引用工程里的任何其它自定义类型，保证本文件可以单独编译。
//  - 持久化：UserDefaults（key 前缀 "MinisX."），不需要额外存储层。
//
//  典型用法：
//      // 根视图
//      RootView().tint(AppThemeManager.shared.accentColor)
//      // 或者（推荐，渐变开关生效时用渐变着色）
//      RootView().minisXThemeTint()
//
//      // 读取
//      let color = AppThemeManager.shared.accentColor
//      let radius = AppThemeManager.shared.bubbleCornerRadius
//

import Combine
import Foundation
import SwiftUI

// MARK: - 配色预设

/// 六套预设主题配色。
///
/// 每个 case 都提供中文名 `title`、主色 `color`、渐变的第二色标
/// `secondaryColor` 以及组合后的 `gradient`。
/// `rawValue` 直接作为 UserDefaults 的持久化值，新增 case 时旧数据
/// 会由 `AppAccent(rawValue:) ?? .fallback` 兜底，不会崩。
enum AppAccent: String, CaseIterable, Identifiable, Codable {
    case blue
    case purple
    case orange
    case green
    case pink
    case teal

    /// 稳定 id，等于 `rawValue`，供 `ForEach` / `Picker` 使用。
    var id: String { rawValue }

    /// 中文显示名（设置页色块下方文案）。
    var title: String {
        switch self {
        case .blue:   return "系统蓝"
        case .purple: return "紫"
        case .orange: return "橙"
        case .green:  return "绿"
        case .pink:   return "粉"
        case .teal:   return "青"
        }
    }

    /// 主色。取 Apple 系统色（Light 外观）的 sRGB 值，中明度，
    /// 浅色 / 深色外观下都保持可读，因此不需要 UIKit 动态色。
    var color: Color {
        switch self {
        case .blue:   return Color(red: 0.00, green: 0.48, blue: 1.00)   // #007AFF
        case .purple: return Color(red: 0.69, green: 0.32, blue: 0.87)   // #AF52DE
        case .orange: return Color(red: 1.00, green: 0.58, blue: 0.00)   // #FF9500
        case .green:  return Color(red: 0.20, green: 0.78, blue: 0.35)   // #34C759
        case .pink:   return Color(red: 1.00, green: 0.18, blue: 0.33)   // #FF2D55
        case .teal:   return Color(red: 0.19, green: 0.69, blue: 0.78)   // #30B0C7
        }
    }

    /// 渐变的第二个色标（与 `color` 组合成对角渐变），普遍比主色更亮/邻近色相。
    var secondaryColor: Color {
        switch self {
        case .blue:   return Color(red: 0.35, green: 0.78, blue: 0.98)   // #5AC8FA
        case .purple: return Color(red: 0.35, green: 0.34, blue: 0.84)   // #5856D6
        case .orange: return Color(red: 1.00, green: 0.80, blue: 0.00)   // #FFCC00
        case .green:  return Color(red: 0.53, green: 0.90, blue: 0.60)   // #87E59A
        case .pink:   return Color(red: 1.00, green: 0.39, blue: 0.51)   // #FF6482
        case .teal:   return Color(red: 0.00, green: 0.78, blue: 0.75)   // #00C7BE
        }
    }

    /// 对角渐变（左上 → 右下）。
    ///
    /// 返回类型保持可选（任务书要求「可选 gradient」）：当前六套配色都返回
    /// 非 nil，调用方用 `accent.gradient ?? AnyShapeStyle(accent.color)` 或
    /// `AppThemeManager.shared.accentGradient`（内部已兜底）都不会崩。
    var gradient: LinearGradient? {
        LinearGradient(
            colors: [color, secondaryColor],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// 非法 / 缺失持久化值时的兜底配色。
    static var fallback: AppAccent { .blue }
}

// MARK: - 气泡风格

/// 消息气泡风格：标准 / 圆润 / 紧凑。
///
/// 只提供「几何参数」，具体渲染仍由消息行自己完成，避免本文件与聊天
/// 视图产生耦合。`rawValue` 作为 UserDefaults 持久化值。
enum MessageBubbleStyle: String, CaseIterable, Identifiable, Codable {
    case standard
    case rounded
    case compact

    var id: String { rawValue }

    /// 中文显示名。
    var title: String {
        switch self {
        case .standard: return "标准"
        case .rounded:  return "圆润"
        case .compact:  return "紧凑"
        }
    }

    /// 设置页副标题（一行说明）。
    var subtitle: String {
        switch self {
        case .standard: return "经典气泡，中等圆角与内边距。"
        case .rounded:  return "更大圆角与内边距，观感更柔和。"
        case .compact:  return "更小圆角与更窄气泡，一屏显示更多内容。"
        }
    }

    /// 设置页行首图标（SF Symbols，全部 iOS 13+ 可用）。
    var symbolName: String {
        switch self {
        case .standard: return "rectangle"
        case .rounded:  return "capsule"
        case .compact:  return "rectangle.compress.vertical"
        }
    }

    /// 气泡圆角半径。
    var cornerRadius: CGFloat {
        switch self {
        case .standard: return 18
        case .rounded:  return 24
        case .compact:  return 10
        }
    }

    /// 气泡水平内边距。
    var horizontalPadding: CGFloat {
        switch self {
        case .standard: return 14
        case .rounded:  return 16
        case .compact:  return 10
        }
    }

    /// 气泡垂直内边距。
    var verticalPadding: CGFloat {
        switch self {
        case .standard: return 10
        case .rounded:  return 12
        case .compact:  return 7
        }
    }

    /// 气泡最大宽度占所在容器宽度的比例。
    var maxWidthRatio: CGFloat {
        switch self {
        case .standard: return 0.78
        case .rounded:  return 0.82
        case .compact:  return 0.68
        }
    }

    /// 统一的圆角样式（连续曲率，与系统观感一致）。
    var cornerStyle: RoundedCornerStyle { .continuous }

    /// 生成气泡形状，供 `.clipShape(_:)` 使用。
    func shape() -> RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: cornerStyle)
    }
}

// MARK: - 主题管理器

/// 全局主题（强调色 + 气泡风格 + 渐变开关）。
///
/// 单例、`@MainActor`、`ObservableObject`；所有属性写入即持久化到
/// UserDefaults，读取时若数据非法自动回落默认值。
///
/// 使用方式：
/// ```swift
/// @ObservedObject private var theme = AppThemeManager.shared
/// ```
@MainActor
final class AppThemeManager: ObservableObject {

    // MARK: 单例

    /// 全局唯一实例。
    static let shared = AppThemeManager()

    // MARK: UserDefaults keys

    /// 强调色持久化 key。
    static let accentStorageKey = "MinisX.accentColor"
    /// 气泡风格持久化 key。
    static let bubbleStyleStorageKey = "MinisX.bubbleStyle"
    /// 渐变强调色开关持久化 key。
    static let gradientStorageKey = "MinisX.useGradientAccent"

    // MARK: 默认值

    /// 默认强调色：系统蓝（与改版前观感一致）。
    static let defaultAccent: AppAccent = .blue
    /// 默认气泡风格：标准。
    static let defaultBubbleStyle: MessageBubbleStyle = .standard
    /// 默认是否使用渐变强调色：关闭（不改动原有观感，由用户主动开启）。
    static let defaultUseGradientAccent: Bool = false

    // MARK: 状态（写入即持久化）

    /// 当前强调色。
    @Published var accent: AppAccent {
        didSet {
            guard accent != oldValue else { return }
            defaults.set(accent.rawValue, forKey: Self.accentStorageKey)
        }
    }

    /// 当前消息气泡风格。
    @Published var bubbleStyle: MessageBubbleStyle {
        didSet {
            guard bubbleStyle != oldValue else { return }
            defaults.set(bubbleStyle.rawValue, forKey: Self.bubbleStyleStorageKey)
        }
    }

    /// 是否使用渐变强调色（开启后 `accentGradient` / `tintStyle` 走渐变）。
    @Published var useGradientAccent: Bool {
        didSet {
            guard useGradientAccent != oldValue else { return }
            defaults.set(useGradientAccent, forKey: Self.gradientStorageKey)
        }
    }

    /// 注入用的 UserDefaults（默认 `.standard`；测试可传 suite）。
    private let defaults: UserDefaults

    // MARK: 初始化

    /// 私有初始化：外部一律通过 `AppThemeManager.shared` 访问。
    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let storedAccent = defaults.string(forKey: Self.accentStorageKey) ?? ""
        self.accent = AppAccent(rawValue: storedAccent) ?? Self.defaultAccent

        let storedBubble = defaults.string(forKey: Self.bubbleStyleStorageKey) ?? ""
        self.bubbleStyle = MessageBubbleStyle(rawValue: storedBubble) ?? Self.defaultBubbleStyle

        self.useGradientAccent = defaults.object(forKey: Self.gradientStorageKey) as? Bool
            ?? Self.defaultUseGradientAccent
    }

    // MARK: 便捷读取 —— 配色

    /// 当前强调色（`accent.color` 的简写），可直接给 `.tint(_:)` / `.foregroundStyle(_:)`。
    var accentColor: Color { accent.color }

    /// 当前渐变的第二色标。
    var accentSecondaryColor: Color { accent.secondaryColor }

    /// 当前渐变（始终非 nil；`AppAccent.gradient` 为 nil 时退化为纯色渐变）。
    var accentGradient: LinearGradient {
        accent.gradient
            ?? LinearGradient(
                colors: [accent.color, accent.color],
                startPoint: .top,
                endPoint: .bottom
            )
    }

    /// 「当前实际生效」的强调样式：开了渐变开关就是渐变，否则是纯色。
    /// 供 `.foregroundStyle(_:)` / `.background(_:)` 直接使用（iOS 16+）。
    var tintStyle: AnyShapeStyle {
        useGradientAccent ? AnyShapeStyle(accentGradient) : AnyShapeStyle(accentColor)
    }

    // MARK: 便捷读取 —— 气泡

    /// 气泡圆角半径（跟随 `bubbleStyle`）。
    var bubbleCornerRadius: CGFloat { bubbleStyle.cornerRadius }
    /// 气泡水平内边距（跟随 `bubbleStyle`）。
    var bubbleHorizontalPadding: CGFloat { bubbleStyle.horizontalPadding }
    /// 气泡垂直内边距（跟随 `bubbleStyle`）。
    var bubbleVerticalPadding: CGFloat { bubbleStyle.verticalPadding }
    /// 气泡最大宽度比例（跟随 `bubbleStyle`）。
    var bubbleMaxWidthRatio: CGFloat { bubbleStyle.maxWidthRatio }
    /// 气泡形状（跟随 `bubbleStyle`），供 `.clipShape(_:)` 使用。
    var bubbleShape: RoundedRectangle { bubbleStyle.shape() }

    // MARK: 便捷读取 —— 选中判断

    /// 指定配色是否为当前选中项。
    func isSelected(_ accent: AppAccent) -> Bool { self.accent == accent }

    /// 指定气泡风格是否为当前选中项。
    func isSelected(_ style: MessageBubbleStyle) -> Bool { self.bubbleStyle == style }

    // MARK: 是否已偏离默认

    /// 任一主题项与默认值不同即为 true（设置页用来决定是否显示「恢复默认」）。
    var isModifiedFromDefaults: Bool {
        accent != Self.defaultAccent
            || bubbleStyle != Self.defaultBubbleStyle
            || useGradientAccent != Self.defaultUseGradientAccent
    }

    // MARK: 操作

    /// 恢复全部主题项为默认值（并持久化）。
    func resetToDefaults() {
        accent = Self.defaultAccent
        bubbleStyle = Self.defaultBubbleStyle
        useGradientAccent = Self.defaultUseGradientAccent
    }

    /// 一次性设置全部主题项（方便「主题预设」类入口复用）。
    func apply(accent: AppAccent,
               bubbleStyle: MessageBubbleStyle,
               useGradientAccent: Bool) {
        self.accent = accent
        self.bubbleStyle = bubbleStyle
        self.useGradientAccent = useGradientAccent
    }
}

// MARK: - 全局着色 View 扩展（可选集成点）

/// 把当前主题的强调色应用为整棵子树的 tint。
///
/// 用法（根视图）：
/// ```swift
/// ContentView().minisXThemeTint()
/// ```
/// 内部使用 `@ObservedObject`，配色变化时自动刷新。
struct MinisXThemeTintModifier: ViewModifier {
    @ObservedObject private var theme = AppThemeManager.shared

    func body(content: Content) -> some View {
        content.tint(theme.accentColor)
    }
}

extension View {
    /// 把 `AppThemeManager` 的强调色应用到整个视图子树（等价于 `.tint(_:)` 的响应式版本）。
    func minisXThemeTint() -> some View {
        modifier(MinisXThemeTintModifier())
    }
}
