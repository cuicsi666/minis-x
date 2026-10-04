//
//  UsageTrendChart.swift
//  MinisApp
//
//  Minis_X — 输出 Token 趋势（纯 SwiftUI Path 手绘柱状图，iOS 16 兼容）。
//

import SwiftUI

struct UsageTrendChart: View {

    let samples: [UsageSample]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("输出 Token 趋势")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                if !samples.isEmpty {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }

            if samples.isEmpty {
                Text("暂无数据")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 18)
            } else {
                GeometryReader { geo in
                    let bars = Array(samples.suffix(40))
                    let peak = max(bars.map { $0.outputTokens }.max() ?? 1, 1)
                    let spacing: CGFloat = 2
                    let total = CGFloat(bars.count) * spacing
                    let barWidth = max((geo.size.width - total) / CGFloat(bars.count), 1)

                    HStack(alignment: .bottom, spacing: spacing) {
                        ForEach(bars) { s in
                            let ratio = CGFloat(s.outputTokens) / CGFloat(peak)
                            Rectangle()
                                .fill(s.outputTokens >= peak ? Color.accentColor
                                      : Color.accentColor.opacity(0.55))
                                .frame(width: barWidth,
                                       height: max(2, geo.size.height * ratio))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 96)
            }

            HStack {
                Text(earliest)
                Spacer()
                Text("最新")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }

    private var summary: String {
        let store = UsageTrendStore.shared
        return "总计 \(store.totalOutput) · 均值 \(store.averageOutput) · 峰值 \(store.peakOutput)"
    }

    private var earliest: String {
        guard let first = samples.first else { return "—" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: first.date)
    }
}
