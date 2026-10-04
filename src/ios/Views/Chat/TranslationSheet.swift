//
//  TranslationSheet.swift
//  MinisApp
//
//  Minis_X — 消息翻译展示页（原文 / 译文 / 复制）。
//

import SwiftUI
import UIKit

struct TranslationSheet: View {

    let messageId: String
    let text: String

    @ObservedObject private var service = MessageTranslationService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var copied = false

    var body: some View {
        NavigationStack {
            List {
                Section("原文") {
                    Text(text)
                        .font(.subheadline)
                        .textSelection(.enabled)
                }

                Section("译文") {
                    if let out = service.cachedTranslation(for: messageId) {
                        Text(out)
                            .font(.subheadline)
                            .textSelection(.enabled)
                    } else if service.inFlight.contains(messageId) {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("正在翻译…")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("点右上角「翻译」开始")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(Text("翻译"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            await service.translate(messageId: messageId, text: text)
                        }
                    } label: {
                        Label(copied ? "已复制" : "翻译",
                              systemImage: copied ? "checkmark" : "character.book.closed")
                    }
                    .disabled(service.inFlight.contains(messageId))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if let out = service.cachedTranslation(for: messageId) {
                            UIPasteboard.general.string = out
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                                copied = false
                            }
                        }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    }
                    .disabled(service.cachedTranslation(for: messageId) == nil)
                }
            }
            .task {
                if service.cachedTranslation(for: messageId) == nil,
                   !service.inFlight.contains(messageId) {
                    await service.translate(messageId: messageId, text: text)
                }
            }
        }
    }
}
