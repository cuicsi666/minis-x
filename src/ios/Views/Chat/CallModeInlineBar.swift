//
//  CallModeInlineBar.swift
//  MinisApp
//
//  Minis_X — 通话模式（内联版）：直接嵌在对话页输入栏里，
//  不再弹出全屏页面。识别文字就地显示、就地发送。
//

import SwiftUI

struct CallModeInlineBar: View {

    @ObservedObject var controller: CallModeController
    var onHangUp: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            MiniWaveform(levels: controller.levels, tint: accent)
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(statusText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(accent)
                Text(caption)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }

            Spacer(minLength: 6)

            Button(action: onHangUp) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [Color(red: 0.95, green: 0.30, blue: 0.32),
                                                     Color(red: 0.78, green: 0.16, blue: 0.20)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: 34, height: 34)
                    Image(systemName: "phone.down.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .accessibilityLabel(Text("挂断"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(accent.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(accent.opacity(0.28), lineWidth: 1)
        )
    }

    private var accent: Color {
        switch controller.state {
        case .listening:  return Color(red: 0.30, green: 0.78, blue: 0.62)
        case .thinking:   return Color(red: 0.98, green: 0.68, blue: 0.28)
        case .speaking:   return Color(red: 0.42, green: 0.62, blue: 0.98)
        case .idle:       return Color.gray
        }
    }

    private var statusText: String {
        switch controller.state {
        case .listening:  return "通话中 · 聆听你说话"
        case .thinking:   return "通话中 · AI 正在思考…"
        case .speaking:   return "通话中 · 正在播报回复"
        case .idle:       return "已挂断"
        }
    }

    private var caption: String {
        if !controller.recognizedText.isEmpty { return controller.recognizedText }
        if !controller.replyText.isEmpty { return controller.replyText }
        return "说完自动发送，回复自动播报"
    }
}

/// 迷你波形（随拾音电平跳动的小竖条）。
private struct MiniWaveform: View {
    let levels: [Float]
    let tint: Color

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<7, id: \.self) { i in
                let v = CGFloat(levels.indices.contains(i) ? levels[i] : 0.05)
                Capsule()
                    .fill(tint)
                    .frame(width: 3, height: 5 + min(v, 1) * 22)
                    .animation(.easeOut(duration: 0.12), value: v)
            }
        }
        .frame(width: 34, height: 32)
        .background(Circle().fill(tint.opacity(0.12)))
    }
}
