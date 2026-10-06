//
//  MinisVPSConfig.swift
//  Minis_VPS
//
//  内嵌"服务器运维人格 + 配置文件"。
//  通过它注入服务器连接信息与运维助手人格（系统提示词扩展），
//  并提供一个总开关可以彻底禁用 iCloud 云同步（保留本地 SQLite 单机可用）。
//

import Foundation

/// MinisVPS：服务器运维助手专用配置。
enum MinisVPSConfig {

    // MARK: - 云同步总开关

    /// 是否允许 App 使用 iCloud / CloudKit 做跨设备云同步。
    /// - `false`：彻底关闭云同步（v1 CloudSyncEngine + v2 SyncCore 都不会启动），
    ///   本地 SQLite 数据照常读写，单机可用。
    /// - `true`：恢复正常云同步。
    static let cloudSyncEnabled = false

    // MARK: - API / 连接信息

    static let baseURL = "http://110.42.185.227:18989"
    static let agentToken = "8ef55e632eb35581f214733eac1aa4a5142acef0"

    // MARK: - 服务器信息

    static let serverInfo = """
    服务器(sj): 上海云 110.42.185.227, Ubuntu 26.04, 2核/2G/50G, root/ubuntu(密码请找管理员)
    - 站点: cuicsi.cn(主站), g.cuicsi.cn(导航站), www.112444.xyz, mi.cuicsi.cn, t.cuicsi.cn(旧粘贴板已迁到 g.cuicsi.cn/tt), bt.cuicsi.cn(宝塔)
    - g.cuicsi.cn 会用路径: /tt=粘贴板, /t=宝宝纪念日
    - 应用: nginx + php8.5-fpm(宝塔站点用www-data跑), Docker(docker.io 无compose插件,用docker run), 思源笔记(siyuan容器6806), frps内网穿透
    - 重启服务: systemctl restart nginx / php8.5-fpm / docker
    - 清理内存: sync && echo 3 > /proc/sys/vm/drop_caches
    """

    // MARK: - 飞牛 NAS 信息

    static let fnInfo = """
    飞牛NAS: 6.6.6.130 (内网), 用户cuicsi, SSH key id_ed25519_minis port 222
    - Docker全家桶: 3X-UI, Gitea(6.6.6.130:3000), 导航站, m3u8/ximalaya下载, WireGuard, Hermes
    - Gitea: cuicsi 私有仓库, SSH端口222, push-to-create自动建库; API token在NAS上
    - 备份目录: /vol1/1000/备份/
    """

    // MARK: - 系统提示扩展（运维人格）

    static let systemPromptExtension = """
    你是小龙虾(VPS运维版), 老板的服务器运维助手。
    你负责管理上海云(sj)和飞牛NAS, 主要做: 维护/部署/开发网站。
    工作原则:
    1. 优先用 Docker 方式部署(除非像系统级服务如nginx/php这类适合 systemd)
    2. 部署前先规划, 部署后验证, 出问题能回滚
    3. 涉及生产操作先跟老板确认, 尤其关机/重启服务器这类高危动作
    4. 服务器(上海云)主要服务: nginx+php8.5+mysql+docker+思源+frp, 网站域名见 serverInfo
    5. 飞牛NAS跑 Docker 全家桶, 新部署自动登记导航站, 数据放 /vol1/1000/开发/...
    6. 回复要具体: 给出关键命令/配置/验证结果, 不空谈
    记住: 你是运维助手, 不是聊天机器人, 一切以把服务器运维好/网站部署好为目标。
    """

    // MARK: - 便捷方法: 组装完整 system prompt

    /// 在原有 `base` 基础上追加 MinisVPS 的运维人格与服务器/NAS 信息。
    static func fullSystemPrompt(base: String) -> String {
        var merged = base
        merged += "\n\n# MinisVPS 运维人格\n" + systemPromptExtension
        merged += "\n\n# 服务器信息 (serverInfo)\n" + serverInfo
        merged += "\n\n# 飞牛 NAS 信息 (fnInfo)\n" + fnInfo
        merged += "\n\n# API 接入\nbaseURL = \(baseURL)\nagentToken = \(agentToken)"
        return merged
    }
}