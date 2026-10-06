//
//  ServerMonitor.swift
//  Minis
//
//  MinisVPS: observable data model + network client for the server
//  floating monitor window and the quick-actions panel.
//
//  - Polls the MinisVPS HTTP API every 1s on a background dispatch queue,
//    then publishes updates on the main actor (Swift 6 safe).
//  - Failure keeps the previous values (no UI flash / no crash).
//  - Swift 6 strict concurrency: the class is @MainActor-isolated and
//    therefore Sendable, so it can be captured by a @Sendable timer closure.
//

import SwiftUI
import Combine

/// The set of remote commands MinisVPS `/action` understands.
enum ServerAction: String, CaseIterable, Identifiable {
    case load
    case cleanMem     = "clean_mem"
    case restartNginx = "restart_nginx"
    case restartPhp   = "restart_php"
    case restartDocker = "restart_docker"
    case reboot
    case shutdown

    var id: String { rawValue }

    /// User-facing (Chinese) label shown on the button.
    var title: String {
        switch self {
        case .load:          return "查看负载"
        case .cleanMem:      return "释放内存"
        case .restartNginx:  return "重启 Nginx"
        case .restartPhp:    return "重启 PHP"
        case .restartDocker: return "重启 Docker"
        case .reboot:        return "重启服务器"
        case .shutdown:      return "关机"
        }
    }

    /// SF Symbol used on the button / confirm dialog.
    var symbol: String {
        switch self {
        case .load:           return "gauge"
        case .cleanMem:       return "memorychip"
        case .restartNginx:   return "arrow.clockwise"
        case .restartPhp:     return "arrow.trianglehead.2.clockwise"
        case .restartDocker:  return "shippingbox"
        case .reboot:         return "power.circle"
        case .shutdown:       return "power"
        }
    }

    /// High-risk commands require an explicit user confirmation.
    var isDangerous: Bool { self == .reboot || self == .shutdown }

    /// Short English key for a sub-row in the detail cards.
    var message: String {
        switch self {
        case .load:          return "服务器负载、内存与磁盘概览"
        case .cleanMem:      return "释放 Linux 内存页缓存"
        case .restartNginx:  return "重载 Nginx 服务"
        case .restartPhp:    return "重启 PHP-FPM 服务"
        case .restartDocker: return "重启 Docker 守护进程"
        case .reboot:        return "执行系统 reboot"
        case .shutdown:      return "执行系统 shutdown"
        }
    }

    /// The raw value the API expects (already == rawValue except .load).
    var apiValue: String {
        self == .load ? "load" : rawValue
    }
}

/// Observable model driving `ServerMonitorFloatingView` and
/// `ServerQuickActionsView`. A single shared instance is used app-wide so
/// there is only ever one poll loop per process.
@MainActor
final class ServerMonitor: ObservableObject {
    /// Shared instance consumed by the floating window and quick actions.
    static let shared = ServerMonitor()

    // MARK: - Endpoint configuration
    private static let baseURLString = "http://110.42.185.227:18989"
    private static let authToken     = "8ef55e632eb35581f214733eac1aa4a5142acef0"
    /// Backoff / timeout for URLSession requests.
    private static let requestTimeout: TimeInterval = 3
    /// Poll interval in seconds.
    private static let pollInterval: TimeInterval = 1
    /// Every `kFullPollEveryTicks` ticks we additionally fetch the heavier
    /// `/status` endpoint for net / uptime / memory detail.
    private static let fullPollEveryTicks = 5
    /// If a controller is not expanded, skip heavy detail fetches entirely.
    private var wantsFullDetail = true

    // MARK: - Published metrics (drives the UI at 1 Hz)
    @Published var cpu: Double = 0
    @Published var mem: Double = 0
    @Published var disk: Double = 0
    @Published var load: Double = 0
    @Published var host: String = "VM"
    @Published var cores: Int = 0
    @Published var netRx: String = "--"
    @Published var netTx: String = "--"
    @Published var uptime: String = "--"
    @Published var memUsed: String = "--"
    @Published var memTotal: String = "--"
    @Published var diskUsed: String = "--"
    @Published var diskTotal: String = "--"
    @Published var isRunning = false
    /// Non-nil while a quick action is in flight (drives spinner state).
    @Published var busyAction: ServerAction?

    private var timer: DispatchSourceTimer?
    private var tick = 0

    // MARK: - Lifecycle (Timer on a background queue)
    func startMonitoring() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + Self.pollInterval,
                   repeating: Self.pollInterval,
                   leeway: .milliseconds(300))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.tickPoll()
            }
        }
        t.resume()
        timer = t
        isRunning = true
    }

    func stopMonitoring() {
        timer?.cancel()
        timer = nil
        isRunning = false
    }

    /// A controller may opt into skipping the heavy full-status poll while it
    /// is collapsed, to lighten load on the small VPS.
    func setWantsFullDetail(_ wants: Bool) {
        wantsFullDetail = wants
    }

    @MainActor
    private func tickPoll() async {
        tick &+= 1
        await pollSimple()
        if wantsFullDetail, tick.isMultiple(of: Self.fullPollEveryTicks) {
            await pollFull()
        }
    }

    // MARK: - Simple status (cpu / mem / disk / load / host)
    private func pollSimple() async {
        do {
            let json = try await get(path: "/status/simple")
            guard let dict = json as? [String: Any] else { return }
            guard let data = dict["data"] as? [String: Any] else { return }
            if let v = data["cpu"]  as? Double { cpu = v }
            if let v = data["mem"]  as? Double { mem = v }
            if let v = data["disk"] as? Double { disk = v }
            if let v = data["load"] as? Double { load = v }
            if let h = data["host"] as? String, !h.isEmpty { host = h }
        } catch {
            // Network failure: keep previous values, drop silently.
            // (Does not set lastError here so the UI does not flash.)
        }
    }

    // MARK: - Full status (net / uptime / cores / memory-disk detail)
    private func pollFull() async {
        do {
            let json = try await get(path: "/status")
            guard let dict = json as? [String: Any] else { return }
            guard let data = dict["data"] as? [String: Any] else { return }
            if let cpuDict = data["cpu"] as? [String: Any] {
                if let c = cpuDict["cores"] as? Int { cores = c }
                if let l = cpuDict["load"] as? Double { load = l }
            }
            if let memDict = data["mem"] as? [String: Any] {
                if let s = memDict["used_h"]  as? String { memUsed = s }
                if let s = memDict["total_h"] as? String { memTotal = s }
                if let s = memDict["free_h"]  as? String { /* optional */ }
            }
            if let diskDict = data["disk"] as? [String: Any] {
                if let s = diskDict["used_h"]  as? String { diskUsed = s }
                if let s = diskDict["total_h"] as? String { diskTotal = s }
            }
            if let netDict = data["net"] as? [String: Any] {
                if let s = netDict["rx_h"] as? String { netRx = s }
                if let s = netDict["tx_h"] as? String { netTx = s }
            }
            if let up = data["uptime"] as? [String: Any] {
                uptime = Self.uptimeString(from: up)
            }
        } catch {
            // Ignore; keep previous values.
        }
    }

    // MARK: - Quick actions
    /// Runs a `/action` command. Returns the server message (or a localized
    /// failure / confirmation-required notice). Never throws.
    func perform(action: ServerAction, confirm: Bool = false) async -> String {
        // Guard: dangerous actions without confirm return early rather than
        // attempting the call (belt and braces — mirror of server contract).
        if action.isDangerous, !confirm {
            return "危险操作需要二次确认"
        }
        busyAction = action
        defer { busyAction = nil }

        var params: [String: Any] = ["action": action.apiValue]
        if confirm {
            params["confirm"] = true
        }

        do {
            let json = try await post(path: "/action", json: params)
            guard let dict = json as? [String: Any] else {
                return "响应解析失败"
            }
            if let need = dict["need_confirm"] as? Bool, need {
                return "此操作需要确认"
            }
            if let msg = dict["msg"] as? String, !msg.isEmpty {
                return msg
            }
            if let ok = dict["ok"] as? Bool, ok {
                return "\(action.title)执行成功"
            }
            if let err = dict["error"] as? String, !err.isEmpty {
                return "失败: \(err)"
            }
            return "已发送"
        } catch {
            return "请求失败：\(error.localizedDescription)"
        }
    }

    // MARK: - Network helpers
    private func get(path: String) async throws -> Any {
        try await request(path: path, method: "GET", body: nil)
    }

    private func post(path: String, json: [String: Any]) async throws -> Any {
        try await request(path: path, method: "POST", body: json)
    }

    private func request(path: String, method: String, body: [String: Any]?) async throws -> Any {
        let urlString = Self.baseURLString + path
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = Self.requestTimeout
        request.setValue("Bearer \(Self.authToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONSerialization.jsonObject(with: data)
    }

    // MARK: - Formatting helpers
    private static func uptimeString(from up: [String: Any]) -> String {
        let days  = (up["days"]  as? Int) ?? 0
        let hours = (up["hours"] as? Int) ?? 0
        let mins  = (up["mins"]  as? Int) ?? 0
        if days > 0 {
            return "\(days)天 \(hours)小时 \(mins)分"
        }
        if hours > 0 {
            return "\(hours)小时 \(mins)分"
        }
        return "\(mins)分"
    }
}

/// Tiny shared formatter for a percentage value.
enum MonitorFormat {
    static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value)
    }
}