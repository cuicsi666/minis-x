//
//  ThemeColorSettingsView.swift
//  Minis_X
//
//  功能 #8：主题配色系统 —— 设置页
//
//  「外观」页里的主题配色子页：强调色 6 选 1 + 实时预览 + 气泡风格 3 选 1
//  + 渐变强调色开关。直接读写 AppThemeManager.shared，无中间状态。
//
//  自包含：只依赖 SwiftUI + AppThemeManager（同批新增的另一文件）。
//

import SwiftUI

/// 主题配色设置页（Form 风格）。
///
/// 接入方式（把 `ThemeColorSettingsView()` 放进任意 NavigationStack 内即可）：
/// ```swift
/// NavigationLink("主题配色") { ThemeColorSettingsView() }
/// ```
struct ThemeColorSettingsView: View {

    /// 直接观察全局单例，改动即时生效并持久化。
    @ObservedObject private var theme = AppThemeManager.shared

    var body: some View {
        Form {
            accentSection
            previewSection
            bubbleStyleSection
            optionsSection
            if theme.isModifiedFromDefaults {
                resetSection
            }
        }
        .navigationTitle("主题配色")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - 强调色（6 个圆形色块）

    private var accentSection: some View {
        Section {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 56), spacing: 8)],
                spacing: 12
            ) {
                ForEach(AppAccent.allCases) { accent in
                    AccentSwatch(
                        accent: accent,
                        isSelected: theme.accent == accent,
                        useGradient: theme.useGradientAccent
                    ) {
                        theme.accent = accent
                    }
                }
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
        } header: {
            Text("强调色")
        } footer: {
            Text("选择 App 的强调色，按钮、开关、聊天气泡等会同步更新。")
        }
    }

    // MARK: - 实时预览

    private var previewSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                previewBubble("对方发来的消息：白色 / 次级背景气泡，不跟随强调色。", isUser: false)
                previewBubble("我发出的消息：跟随当前强调色与气泡风格。", isUser: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
        } header: {
            Text("实时预览")
        } footer: {
            Text("预览会随配色、气泡风格与渐变开关实时变化。")
        }
    }

    /// 一条示例气泡。
    private func previewBubble(_ text: String, isUser: Bool) -> some View {
        HStack(spacing: 0) {
            if isUser { Spacer(minLength: 24) }

            Text(text)
                .font(.subheadline)
                .foregroundStyle(isUser ? Color.white : Color.primary)
                .padding(.horizontal, theme.bubbleHorizontalPadding)
                .padding(.vertical, theme.bubbleVerticalPadding)
                .background(
                    isUser
                        ? theme.tintStyle
                        : AnyShapeStyle(Color.gray.opacity(0.18))
                )
                .clipShape(
                    RoundedRectangle(cornerRadius: theme.bubbleCornerRadius, style: .continuous)
                )

            if !isUser { Spacer(minLength: 24) }
        }
    }

    // MARK: - 气泡风格（3 选 1）

    private var bubbleStyleSection: some View {
        Section {
            ForEach(MessageBubbleStyle.allCases) { style in
                Button {
                    theme.bubbleStyle = style
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: style.symbolName)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(theme.accentColor)
                            .frame(width: 26)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(style.title)
                                .foregroundStyle(.primary)
                            Text(style.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 8)

                        if theme.bubbleStyle == style {
                            Image(systemName: "checkmark")
                                .fontWeight(.semibold)
                                .foregroundStyle(theme.accentColor)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("消息气泡")
        } footer: {
            Text("调整气泡的圆角、内边距与最大宽度，改动立即应用到聊天界面。")
        }
    }

    // MARK: - 其它选项

    private var optionsSection: some View {
        Section {
            Toggle(isOn: $theme.useGradientAccent) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("使用渐变强调色")
                    Text("渐变色用于按钮与用户气泡")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("高级")
        } footer: {
            Text("关闭时使用纯色（系统观感）；开启后强调色以对角渐变呈现。")
        }
    }

    // MARK: - 恢复默认

    private var resetSection: some View {
        Section {
            Button {
                theme.resetToDefaults()
            } label: {
                Text("恢复默认主题")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .foregroundStyle(.red)
            }
        } footer: {
            Text("默认：系统蓝 + 标准气泡 + 关闭渐变。")
        }
    }
}

// MARK: - 单个色块

/// 强调色圆形色块：选中时打勾。
private struct AccentSwatch: View {
    let accent: AppAccent
    let isSelected: Bool
    let useGradient: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(fillStyle)
                        .frame(width: 44, height: 44)

                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .padding(3)
                .overlay {
                    Circle()
                        .strokeBorder(
                            isSelected ? Color.primary.opacity(0.45) : Color.primary.opacity(0.10),
                            lineWidth: isSelected ? 2 : 1
                        )
                }

                Text(accent.title)
                    .font(.caption)
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(accent.title))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// 渐变开关打开时色块本身就是渐变，所见即所得。
    private var fillStyle: AnyShapeStyle {
        if useGradient, let gradient = accent.gradient {
            return AnyShapeStyle(gradient)
        }
        return AnyShapeStyle(accent.color)
    }
}
