//
//  MessageImageExporter.swift
//  MinisApp
//
//  Minis_X — 把一条消息渲染成可分享的长图（ImageRenderer, iOS 16+）。
//

import SwiftUI
import UIKit

enum MessageImageExporter {

    /// 轻量 Markdown 清理：去掉代码围栏与粗体/斜体符号。
    static func cleanMarkdown(_ input: String) -> String {
        var text = input
        // ```lang ... ```
        text = text.replacingOccurrences(of: "```[a-zA-Z0-9_+-]*\n", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "```", with: "")
        text = text.replacingOccurrences(of: "**", with: "")
        text = text.replacingOccurrences(of: "##", with: "")
        text = text.replacingOccurrences(of: "`", with: "")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 渲染一张 540pt 宽（@2x）的分享卡片图。ImageRenderer 是 MainActor 隔离的。
    @MainActor
    static func renderCard(text: String, title: String? = nil, isDark: Bool = false) -> UIImage? {
        let body = cleanMarkdown(text)
        guard !body.isEmpty else { return nil }

        let stamp = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "zh_CN")
            f.dateFormat = "yyyy-MM-dd HH:mm"
            return f.string(from: Date())
        }()

        let card = ZStack {
            Rectangle()
                .fill(Color(red: 0.07, green: 0.08, blue: 0.10))
                .frame(width: 540)

            VStack(alignment: .leading, spacing: 18) {
                // 标题栏
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(LinearGradient(colors: [Color(red: 0.42, green: 0.62, blue: 0.98),
                                                      Color(red: 0.30, green: 0.78, blue: 0.62)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 34, height: 34)
                        .overlay(Text("X").font(.system(size: 17, weight: .bold)).foregroundStyle(.white))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title?.isEmpty == false ? (title ?? "Minis_VPS") : "Minis_VPS")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                        Text(stamp)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    Spacer(minLength: 0)
                }

                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)

                Text(body)
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineSpacing(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)

                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)

                HStack {
                    Spacer(minLength: 0)
                    Text("由 Minis_X 生成")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
            .padding(28)
            .frame(width: 540, alignment: .topLeading)
        }
        .frame(width: 540)

        let renderer = ImageRenderer(content: card)
        renderer.scale = 2.0
        renderer.proposedSize = ProposedViewSize(width: 540, height: nil)
        return renderer.uiImage
    }
}
