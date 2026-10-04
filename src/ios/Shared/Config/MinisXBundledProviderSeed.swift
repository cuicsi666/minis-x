//
//  MinisXBundledProviderSeed.swift
//  MinisApp
//
//  Minis_X 功能 #1 —— 内置模型开箱即用（zero-config bundled provider）。
//
//  WHAT THIS DOES
//  --------------
//  首次安装启动时，App 内已经存在一个可用的 LLM provider，用户不需要粘贴
//  任何 API key 就能直接开始中文对话：
//    • 一个 enabled 的 OpenAI-compatible `ProviderInstance`，label 为 "ipix"，
//      base URL 指向 https://ai.ipix.ink/v1（appendV1Suffix = true），
//      credentialType = .apiKey，key 直接写进 Keychain；
//    • 该端点的模型目录作为 `ModelEntry` 落库（离线可用的静态种子；正常刷新
//      路径会用真实 /v1/models 结果做一次对账）；
//    • 一个 fallback 策略的 `ModelGroup`（"ipix 默认模型"），头号成员是
//      DeepSeek-V4-Flash-0731，并写进 `defaultPrimaryGroupId`，这样新建会话会
//      走 AIChatViewModel 的 tier-1 default-group 绑定路径。
//
//  WHY IT IS SAFE
//  --------------
//  * 幂等：UserDefaults 标记保证每个安装只注入一次；用户手动删除内置 provider
//    之后也不会被重新注入（标记在“跳过”时同样写入）。
//  * 非破坏性：只通过 ProviderConfigStore 自己的公开 mutation API 追加，且当
//    store 里已有 provider 实例（iCloud 恢复 / 备份还原 / 用户自己配置）时整体
//    跳过；只有在 `defaultPrimaryGroupId` 为 nil 时才会设置默认组，绝不覆盖用户
//    已有默认组。
//  * 落盘校验：写入后回读 provider-config.json 确认实例 id 真的写进去了，否则
//    不写标记（下次启动重试），避免“pre-first-unlock 启动、save() 被抑制”时把
//    种子永久丢掉。
//
//  明文 key 只存在于本文件（产品需求：开箱即用），写入 Keychain 后不会再被读回
//  或打印到任何日志。
//

import Foundation
import os.log

private let logger = AppLogger(category: "MinisXBundledProviderSeed")

/// 内置 provider 的一次性种子。见文件头注释。
@MainActor
enum MinisXBundledProviderSeed {

    // MARK: - Markers

    /// 一次性标记。存在 == “本安装已经跑过内置种子”。
    /// 即使什么都没插入（store 非空 / 已存在同名 provider）也会写入，
    /// 因此用户删掉内置 provider 后不会再被注入。
    static let didSeedDefaultsKey = "MinisX.didSeedBundledProviders"

    /// 次级标记：本次生成的实例 id。防止 Bool 标记丢失（例如 UserDefaults 被部分
    /// 恢复）时再注入一次。
    static let seededInstanceIdKey = "MinisX.bundledProviderInstanceId"

    // MARK: - Bundled configuration

    /// Settings → Providers 里显示的名字。
    private static let providerLabel = "ipix"

    /// OpenAI-compatible 端点根地址。`appendV1Suffix = true` 与
    /// `ProviderInstance.resolvedBaseURL(default:)` 的既有约定一致：
    /// 去掉尾部 "/v1" 后由请求侧重新拼接。
    private static let providerBaseURL = "https://ai.ipix.ink/v1"

    /// 默认组头号成员（fallback 策略解析到第一个可用成员）。
    private static let primaryModelID = "DeepSeek-V4-Flash-0731"

    /// 默认组其余成员，按 fallback 顺序。只有存在于 `catalog` 的 id 才会被使用。
    private static let fallbackModelIDs = ["DeepSeek-V4.1-Flash", "Qwen3.8-Max"]

    /// 种子默认组的显示名。
    private static let defaultGroupName = "ipix 默认模型"

    /// true = 只在“完全没有 provider 实例”的全新 store 上注入（即“首次安装”）。
    /// 改成 false 可以让已经存在（同步/还原来的）provider 的设备也追加内置 provider。
    private static let requiresEmptyProviderStore = true

    /// 内置 API key。仅通过
    /// `ProviderKeychainHelper.saveAPIKey(_:instanceId:)` 写入 Keychain，从不打印。
    private static let bundledAPIKey = "sk_R_F66Jx0NOb947w_BzNmZuihxsmFxZLtFu9saJOHjO0"

    /// 单个种子模型。`displayName` 与端点返回的 `display_name` 一致；
    /// `reasoning` 与端点 `reasoning.enabled` 一致。
    private struct SeedModel {
        let id: String
        let displayName: String
        let reasoning: Bool
    }

    /// 端点 `/v1/models` 的完整目录快照（实测 23 个模型），保证首次启动即使离线也
    /// 能在模型选择器里看到全部模型。常规刷新路径会用实时列表对账：
    /// 不在实时列表里的 id 会被 `ProviderConfigStore.replaceEntries` 清理掉。
    private static let catalog: [SeedModel] = [
        SeedModel(id: "GLM-5.1", displayName: "GLM-5.1", reasoning: false),
        SeedModel(id: "GLM-5.2", displayName: "GLM-5.2", reasoning: true),
        SeedModel(id: "GLM-5.3-Flash", displayName: "GLM-5.3-Flash", reasoning: true),
        SeedModel(id: "GLM-5.3", displayName: "GLM-5.3", reasoning: true),
        SeedModel(id: "Kimi-K2.6", displayName: "Kimi-K2.6", reasoning: false),
        SeedModel(id: "Kimi-K2.7-Code", displayName: "Kimi-K2.7-Code", reasoning: false),
        SeedModel(id: "Kimi-K2.8-Preview", displayName: "Kimi-K2.8-Preview", reasoning: false),
        SeedModel(id: "Kimi-K3", displayName: "Kimi-K3", reasoning: false),
        SeedModel(id: "Qwen3.7-Flash", displayName: "Qwen3.7-Flash", reasoning: false),
        SeedModel(id: "Qwen3.7-Plus", displayName: "Qwen3.7-Plus", reasoning: false),
        SeedModel(id: "Qwen3.8-Flash", displayName: "Qwen3.8-Flash", reasoning: false),
        SeedModel(id: "Qwen3.8-Max", displayName: "Qwen3.8-Max", reasoning: false),
        SeedModel(id: "DeepSeek-V4-Flash-0731", displayName: "DeepSeek-V4-Flash-0731", reasoning: true),
        SeedModel(id: "DeepSeek-V4-Pro", displayName: "DeepSeek-V4-Pro", reasoning: true),
        SeedModel(id: "DeepSeek-V4.1-Flash", displayName: "DeepSeek-V4.1-Flash", reasoning: false),
        SeedModel(id: "DeepSeek-V4-Pro-0813", displayName: "DeepSeek-V4-Pro-0813", reasoning: true),
        SeedModel(id: "MiniMax-M2.7", displayName: "MiniMax-M2.7", reasoning: false),
        SeedModel(id: "MiniMax-M3", displayName: "MiniMax-M3", reasoning: false),
        SeedModel(id: "MiMo-V2.5", displayName: "MiMo-V2.5", reasoning: false),
        SeedModel(id: "MiMo-V2.5-Pro", displayName: "MiMo-V2.5-Pro", reasoning: false),
        SeedModel(id: "Hy3", displayName: "Hy3", reasoning: false),
        SeedModel(id: "Hy4-Preview", displayName: "Hy4-Preview", reasoning: false),
        SeedModel(id: "Doubao-Seed-2.1-Pro", displayName: "Doubao-Seed-2.1-Pro", reasoning: false),
    ]

    // MARK: - Entry point

    /// 启动时调用一次（集成位置见交付报告：`MinisApp.body` → WindowGroup 根视图
    /// `.onAppear`，紧跟在 `ProviderMigration.migrateIfNeeded(store:)` 之后）。
    static func seedIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: didSeedDefaultsKey) else { return }
        guard defaults.string(forKey: seededInstanceIdKey) == nil else { return }

        let store = ProviderConfigStore.shared

        if requiresEmptyProviderStore && !store.instances.isEmpty {
            logger.info("[BundledSeed] skip — provider store already has \(store.instances.count) instance(s)")
            markRunComplete(instanceID: nil)
            return
        }
        if store.instances.contains(where: { $0.label == providerLabel }) {
            logger.info("[BundledSeed] skip — a '\(providerLabel)' provider already exists")
            markRunComplete(instanceID: nil)
            return
        }

        let instance = ProviderInstance(
            label: providerLabel,
            providerType: .openAI,
            credentialType: .apiKey,
            customBaseURL: providerBaseURL,
            appendV1Suffix: true
        )

        // 先写 Keychain：`addInstance` 会立刻发起一次 /v1/models 刷新，
        // 且 ModelGroupRouter 只接受 hasAnyCredential == true 的实例成员。
        ProviderKeychainHelper.saveAPIKey(bundledAPIKey, instanceId: instance.id)
        store.addInstance(instance)

        // 种子模型条目。`addEntry` 按 (instance, model id) 去重并调用
        // `withInferredModality()` 做 models.dev 富化，和 “Add Model” UI 是同一条路径。
        // entry.id == "{instanceId}/{modelId}"（composite key），可安全预计算。
        var entryIDByModelID: [String: String] = [:]
        for seed in catalog {
            let model = LLMModel(
                id: seed.id,
                displayName: seed.displayName,
                provider: providerLabel,
                modalityOverride: .textOnly,
                supportsReasoning: seed.reasoning ? true : nil
            )
            let entry = ModelEntry(providerInstanceId: instance.id, model: model)
            if !store.addEntry(entry) {
                logger.warning("[BundledSeed] entry already present: \(seed.id)")
            }
            entryIDByModelID[seed.id] = entry.id
        }

        // 默认模型组：成员顺序 == fallback 顺序。
        var memberIDs: [String] = []
        for modelID in [primaryModelID] + fallbackModelIDs {
            if let entryID = entryIDByModelID[modelID] { memberIDs.append(entryID) }
        }
        if memberIDs.isEmpty, let first = catalog.first, let entryID = entryIDByModelID[first.id] {
            memberIDs = [entryID]   // 兜底：绝不创建空组
        }

        var groupID: String?
        if !memberIDs.isEmpty {
            let group = ModelGroup(
                name: defaultGroupName,
                memberEntryIds: memberIDs,
                strategy: .fallback,
                fallbackStrategy: .limited
            )
            store.addGroup(group)
            groupID = group.id
            // 绝不覆盖用户/同步已设定的默认组。
            if store.defaultPrimaryGroupId == nil {
                store.defaultPrimaryGroupId = group.id
            }
        }

        // 只有真的落盘才写标记。磁盘配置不可读时（重启后的 pre-first-unlock 启动）
        // `ProviderConfigStore.save()` 会被抑制，此时若写标记就永久丢失种子。
        if let instanceID = persistedInstanceID(instance.id) {
            markRunComplete(instanceID: instanceID)
            logger.info("[BundledSeed] seeded '\(providerLabel)' instance=\(instance.id.prefix(8)) entries=\(entryIDByModelID.count) group=\(groupID?.prefix(8) ?? "nil")")
        } else {
            logger.error("[BundledSeed] seed NOT persisted (config save suppressed?) — will retry next launch")
        }
    }

    // MARK: - Helpers

    /// 回读 provider-config.json，确认新实例 id 真的写进去了。
    /// 返回应记录的实例 id，失败返回 nil。
    private static func persistedInstanceID(_ instanceID: String) -> String? {
        let url = ProviderConfigStore.configFileURLForBackup
        guard let json = try? String(contentsOf: url, encoding: .utf8) else {
            // 读不到文件时以内存态兜底，避免无限重试。
            return ProviderConfigStore.shared.instance(for: instanceID) != nil ? instanceID : nil
        }
        return json.contains(instanceID) ? instanceID : nil
    }

    private static func markRunComplete(instanceID: String?) {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: didSeedDefaultsKey)
        if let instanceID { defaults.set(instanceID, forKey: seededInstanceIdKey) }
    }
}
