//
//  ReadingPreferenceView.swift
//  Minis
//
//  功能：阅读偏好设置页 —— 「字号缩放 + 行距」两个 Slider + 实时预览。
//
//  自包含：只依赖 SwiftUI + ReadingPreferenceStore（同批新增文件）。
//  接入方式（放进任意 NavigationStack 内即可）：
//  ```swift
//  NavigationLink("阅读偏好") { ReadingPreferenceView() }
//  ```
//
//  iOS 16 兼容：未使用任何 iOS 17+ API，也未使用双参数 `.onChange`（本页无需
//  onChange；若后续添加，必须写成单参数 `{ newValue in ... }`）。
//

import Foundation
import SwiftUI

/// 阅读偏好设置页（Form 风格）。
struct ReadingPreferenceView: View {

    /// 直接观察全局单例，改动即时生效并持久化。
    @ObservedObject private var store = ReadingPreferenceStore.shared

    var body: some View {
        Form {
            fontScaleSection
            lineSpacingSection
            previewSection
            if store.isModified {
                resetSection
            }
        }
        .navigationTitle("阅读偏好")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - 字号缩放

    private var fontScaleSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("字号缩放")
                    Spacer()
                    Text(percentText(store.fontScale))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: $store.fontScale,
                    in: ReadingPreferenceStore.fontScaleRange,
                    step: 0.01,
                    minimumValueLabel: Image(systemName: "textformat.size.smaller"),
                    maximumValueLabel: Image(systemName: "textformat.size.larger"),
                    label: {
                        Text("字号缩放")
                    }
                )
            }
            .padding(.vertical, 2)
        } header: {
            Text("字号")
        } footer: {
            Text("按比例缩放聊天正文字号（85% – 140%，默认 100%），与系统「字体大小」档位叠加生效。")
        }
    }

    // MARK: - 行距

    private var lineSpacingSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("行距")
                    Spacer()
                    Text(String(format: "%.2f×", store.lineSpacing))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: $store.lineSpacing,
                    in: ReadingPreferenceStore.lineSpacingRange,
                    step: 0.01,
                    minimumValueLabel: Image(systemName: "text.alignleft") .font(.caption2) .foregroundStyle(.secondary),
                    maximumValueLabel: Image(systemName: "text.alignleft") .font(.caption) .foregroundStyle(.secondary),
                    label: {
                        Text("行距")
                    }
                )
            }
            .padding(.vertical, 2)
        } header: {
            Text("行距")
        } footer: {
            Text("正文字行之间的疏密（1.00× – 1.80×，默认 1.15×），仅影响消息正文，不影响界面其它文字。")
        }
    }

    // MARK: - 实时预览

    private var previewSection: some View {
        Section {
            Text(
                "这是正文预览：调整字号与行距时，这段文字会实时变化。\n"
                + "多读一会儿，找到眼睛最舒服的排版——合适的字号与行距，"
                + "能让长消息读起来更轻松。"
            )
            .font(store.scaledBodyFont)
            .lineSpacing(store.resolvedLineSpacing)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
        } header: {
            Text("实时预览")
        } footer: {
            Text("预览与聊天正文使用同一套字号缩放与行距参数。")
        }
    }

    // MARK: - 恢复默认

    private var resetSection: some View {
        Section {
            Button {
                store.resetToDefaults()
            } label: {
                Text("恢复默认")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .foregroundStyle(.red)
            }
        } footer: {
            Text("默认：字号 100%、行距 1.15×。")
        }
    }

    // MARK: - Helpers

    /// 把 1.0 缩放显示为「100%」。
    private func percentText(_ scale: Double) -> String {
        String(format: "%.0f%%", scale * 100)
    }
}
