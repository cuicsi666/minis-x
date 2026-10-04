//
//  CallModeView.swift
//  MinisApp
//
//  Minis_X — 全新「通话模式」全屏界面。
//
//  视觉：深色渐变背景 + 中央大圆形声波（随拾音电平呼吸）+ 状态文字 +
//  实时字幕 + 底部大圆形挂断按钮。播报/聆听两种状态用不同色相区分。
//
//  只依赖 CallModeController 与标准 SwiftUI（iOS 16 可用 API）。
//

import SwiftUI

struct CallModeView: View {

    @ObservedObject var controller: CallModeController
    @Environment(\.dismiss) private var dismiss

    @State private var pulse = false
    @State private var now = Date()

    private let ticker = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            background

            VStack(spacing: 0) {
                header

                Spacer(minLength: 10)

                orb

                Text(stateText)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.top, 26)

                if let err = controller.errorText {
                    Text(err)
                        .font(.footnote)
                        .foregroundStyle(Color.orange)
                        .multilineTextAlignment(.center)
                        .padding(.top, 8)
                        .padding(.horizontal, 24)
                }

                Spacer(minLength: 10)

                captions

                Spacer(minLength: 10)

                controls
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)
            .padding(.bottom, 26)
        }
        .onAppear { pulse = true }
        .onReceive(ticker) { now = $0 }
        .onChange(of: controller.state) { newValue in
            if newValue == .idle { dismiss() }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Background

    private var background: some View {
        LinearGradient(
            colors: [
                Color(red: 0.06, green: 0.09, blue: 0.16),
                Color(red: 0.10, green: 0.14, blue: 0.24),
                Color(red: 0.05, green: 0.07, blue: 0.13)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("通话中")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                Text(clockText)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
            }
            Spacer()
            HStack(spacing: 7) {
                Circle()
                    .fill(controller.state == .listening ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(controller.state == .listening ? "聆听中" : "处理中")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.10), in: Capsule())
        }
        .padding(.top, 6)
    }

    private var clockText: String {
        let t = Int(controller.elapsed)
        return String(format: "%02d:%02d", t / 60, t % 60)
    }

    // MARK: - Orb

    private var orb: some View {
        let peak = CGFloat(controller.levels.max() ?? 0)

        return ZStack {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .stroke(accentColor.opacity(0.16), lineWidth: 1.5)
                    .frame(width: 214 + CGFloat(i) * 46, height: 214 + CGFloat(i) * 46)
                    .scaleEffect(pulse ? 1.05 : 0.95)
                    .opacity(pulse ? 0.25 : 0.75)
                    .animation(
                        .easeInOut(duration: 1.5).repeatForever(autoreverses: true).delay(Double(i) * 0.22),
                        value: pulse
                    )
            }

            Circle()
                .fill(
                    RadialGradient(
                        colors: [accentColor.opacity(0.95), accentColor.opacity(0.45)],
                        center: .center,
                        startRadius: 8,
                        endRadius: 110
                    )
                )
                .frame(width: 186, height: 186)
                .scaleEffect(1.0 + min(peak, 1) * 0.20)
                .animation(.easeOut(duration: 0.12), value: peak)
                .shadow(color: accentColor.opacity(0.45), radius: 26, x: 0, y: 8)

            Image(systemName: stateIcon)
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(.white)
        }
        .frame(height: 260)
    }

    private var accentColor: Color {
        switch controller.state {
        case .listening:  return Color(red: 0.30, green: 0.78, blue: 0.62)
        case .thinking:   return Color(red: 0.98, green: 0.68, blue: 0.28)
        case .speaking:   return Color(red: 0.42, green: 0.62, blue: 0.98)
        case .idle:       return Color.gray
        }
    }

    private var stateIcon: String {
        switch controller.state {
        case .listening:  return "waveform"
        case .thinking:   return "ellipsis"
        case .speaking:   return "speaker.wave.3.fill"
        case .idle:       return "phone.down.fill"
        }
    }

    private var stateText: String {
        switch controller.state {
        case .listening:  return "请说话…"
        case .thinking:   return "AI 正在思考…"
        case .speaking:   return "正在播报回复…"
        case .idle:       return "已挂断"
        }
    }

    // MARK: - Captions

    private var captions: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !controller.recognizedText.isEmpty {
                captionRow(icon: "person.fill", tint: .white.opacity(0.75), text: controller.recognizedText)
            }
            if !controller.replyText.isEmpty {
                captionRow(icon: "sparkles", tint: accentColor, text: controller.replyText)
            }
            if controller.recognizedText.isEmpty && controller.replyText.isEmpty {
                Text("说完会自动发送，AI 回复会自动念出来")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .frame(height: 156, alignment: .top)
    }

    private func captionRow(icon: String, tint: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 16)
                .padding(.top, 2)
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 46) {
            circleButton(icon: controller.state == .speaking ? "hand.raised.fill" : "mic.slash.fill",
                         label: controller.state == .speaking ? "打断" : "静音",
                         tint: Color.white.opacity(0.14),
                         foreground: .white) {
                if controller.state == .speaking {
                    controller.interruptSpeaking()
                }
            }

            Button {
                controller.hangUp()
            } label: {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color(red: 0.95, green: 0.30, blue: 0.32),
                                         Color(red: 0.78, green: 0.16, blue: 0.20)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 74, height: 74)
                        .shadow(color: Color.red.opacity(0.45), radius: 18, x: 0, y: 6)
                    Image(systemName: "phone.down.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .accessibilityLabel(Text("挂断"))

            circleButton(icon: "speaker.wave.2.fill", label: "免提",
                         tint: Color.white.opacity(0.14), foreground: .white) { }
        }
        .padding(.top, 4)
    }

    private func circleButton(icon: String,
                              label: String,
                              tint: Color,
                              foreground: Color,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Circle().fill(tint).frame(width: 52, height: 52)
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(foreground)
                }
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
    }
}
