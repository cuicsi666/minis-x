//
//  UsageTrendStore.swift
//  MinisApp
//
//  Minis_X — Token 用量趋势数据层（最近 200 个回合样本）。
//

import Combine
import Foundation

struct UsageSample: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var date: Date
    var inputTokens: Int
    var outputTokens: Int
}

final class UsageTrendStore: ObservableObject {

    nonisolated(unsafe) static let shared = UsageTrendStore()

    static let persistenceKey = "MinisX.usageTrend.samples"
    static let maxSamples = 200

    @Published private(set) var samples: [UsageSample] = []

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.persistenceKey),
           let list = try? JSONDecoder().decode([UsageSample].self, from: data) {
            samples = list
        }
    }

    func record(inputTokens: Int, outputTokens: Int) {
        samples.append(UsageSample(date: Date(), inputTokens: inputTokens, outputTokens: outputTokens))
        if samples.count > Self.maxSamples {
            samples.removeFirst(samples.count - Self.maxSamples)
        }
        if let data = try? JSONEncoder().encode(samples) {
            defaults.set(data, forKey: Self.persistenceKey)
        }
    }

    func clear() {
        samples.removeAll()
        defaults.removeObject(forKey: Self.persistenceKey)
    }

    var totalOutput: Int { samples.reduce(0) { $0 + $1.outputTokens } }

    var averageOutput: Int {
        samples.isEmpty ? 0 : totalOutput / samples.count
    }

    var peakOutput: Int { samples.map { $0.outputTokens }.max() ?? 0 }
}
