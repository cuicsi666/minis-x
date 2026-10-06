//
//  ServerQuickActionsView.swift
//  Minis
//
//  MinisVPS: the quick-commands panel. A lazy grid of buttons that invoke the
//  MinisVPS `/action` endpoint:
//
//    释放内存 / 查看负载 / 重启 Nginx / 重启 PHP / 重启 Docker / 重启服务器 / 关机
//
//  High-risk commands (restart server, shutdown) require a second
//  confirmation via an alert — faithful to the server's `confirm` contract.
//  Each button reports the resulting message inline.
//
//  iOS 16+ / Swift 6, SF Symbols only.
//

import SwiftUI

/// Grid panel of one-shot VPS commands. Presented as a sheet from the
/// expanded floating monitor card.
struct ServerQuickActionsView: View {
    @ObservedObject private var monitor = ServerMonitor.shared
    @Environment(\.dismiss) private var dismiss

    @State private var pendingAction: ServerAction?
    @State private var showConfirm = false
    @State private var resultText: String?
    @State private var resultIsError = false
    @State private var runningAction: ServerAction?

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(ServerAction.allCases) { action in
                            actionTile(action)
                        }
                    }

                    if let resultText {
                        resultBanner
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .navigationTitle("快捷指令")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .alert("危险操作确认", isPresented: $showConfirm, presenting: pendingAction) { action in
                Button("取消", role: .cancel) {
                    pendingAction = nil
                }
                Button(action.title, role: .destructive) {
                    let confirmed = action
                    pendingAction = nil
                    run(confirmed, confirm: true)
                }
            } message: { action in
                Text("确定要\(action.title)吗？此操作会中断服务器服务：\n\(action.message)")
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Action tile
    private func actionTile(_ action: ServerAction) -> some View {
        let isRunning = monitor.busyAction == action
        return Button {
            handleTap(action)
        } label: {
            VStack(spacing: 6) {
                if isRunning {
                    ProgressView()
                        .controlSize(.small)
                        .frame(height: 18)
                } else {
                    Image(systemName: action.symbol)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(action.isDangerous ? AnyShapeStyle(.red) : AnyShapeStyle(.blue))
                        .frame(height: 18)
                }
                Text(action.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(action.message)
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 74)
            .padding(.horizontal, 6)
            .background(action.isDangerous
                        ? Color.red.opacity(0.08)
                        : Color.blue.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        action.isDangerous ? Color.red.opacity(0.22) : Color.blue.opacity(0.15),
                        lineWidth: 0.8
                    )
            )
            .disabled(isRunning || monitor.busyAction != nil)
            .opacity(monitor.busyAction != nil && !isRunning ? 0.45 : 1)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Result banner
    @ViewBuilder
    private var resultBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: resultIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(resultIsError ? AnyShapeStyle(.red) : AnyShapeStyle(.green))
            Text(resultText ?? "")
                .font(.system(size: 12, weight: .medium))
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            Button {
                withAnimation { resultText = nil }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(
            (resultIsError ? Color.red : Color.green).opacity(0.09),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    // MARK: - Actions
    private func handleTap(_ action: ServerAction) {
        if action.isDangerous {
            pendingAction = action
            showConfirm = true
        } else {
            run(action, confirm: false)
        }
    }

    private func run(_ action: ServerAction, confirm: Bool) {
        Task {
            let msg = await monitor.perform(action: action, confirm: confirm)
            withAnimation {
                resultIsError = msg.hasPrefix("失败") || msg.hasPrefix("请求失败") || msg == "危险操作需要二次确认"
                resultText = msg
            }
        }
    }
}