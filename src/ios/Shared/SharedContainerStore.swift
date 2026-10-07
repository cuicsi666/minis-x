import Foundation

/// Central directory resolution that replaces the removed App Group shared
/// container (now local Application Support — app-group removed for no-sandbox).
///
/// Compiled into both the main app target and the Share Extension target.
/// IMPORTANT: each process resolves its OWN private local Application Support
/// directory. Cross-process sharing (main app ⇄ FileProvider ⇄ ShareExtension)
/// is no longer possible once the App Group entitlement and its shared
/// container are gone — that trade-off is intentional. Everything still lives
/// under a stable, private, non-temporary location per process, so nothing
/// crashes and the main app's data is fully persistent on disk.
enum AppDirs {
    /// The process's own private Application Support directory. Persistent and
    /// (device) backed up. Never nil — falls back to tmp only as a last resort
    /// so callers can force-unwrap / chain without a crash guard.
    static let appSupport: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    /// Local root that mirrors the former App Group container usage.
    static var sharedRoot: URL { appSupport }

    /// FileProvider-visible root (mirrors the old `MinisFileProvider` folder).
    /// Only user-facing subdirs (shared / skills / memory) live under here.
    static var providerRoot: URL {
        appSupport.appendingPathComponent("MinisFileProvider", isDirectory: true)
    }

    /// Private metadata root (mounted-folders.json, FP diagnostic logs, MCP
    /// config, …), sibling of providerRoot. Never surfaced to iOS Files.
    static var configRoot: URL {
        let url = appSupport.appendingPathComponent("MinisConfig", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Reads and writes PendingShare data to the app's local storage.
/// Compiled into both the main app target and the Share Extension target.
enum SharedContainerStore {
    private static let pendingShareKey = "pendingShare"

    /// Previously the App Group suite. Now just the process-local standard
    /// suite (cross-process handoff is not available without App Group).
    static var sharedDefaults: UserDefaults? {
        .standard
    }

    /// Directory in local storage for transferring attachment files.
    static var sharedFileDirectory: URL? {
        AppDirs.sharedRoot.appendingPathComponent("ShareExtension", isDirectory: true)
    }

    // MARK: - Write (called by Share Extension)

    static func savePendingShare(_ share: PendingShare) {
        guard let defaults = sharedDefaults else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(share) {
            defaults.set(data, forKey: pendingShareKey)
            defaults.synchronize()
        }
    }

    // MARK: - Read & Consume (called by main app)

    static func loadPendingShare() -> PendingShare? {
        guard let defaults = sharedDefaults,
              let data = defaults.data(forKey: pendingShareKey) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PendingShare.self, from: data)
    }

    static func clearPendingShare() {
        sharedDefaults?.removeObject(forKey: pendingShareKey)
        sharedDefaults?.synchronize()
    }

    /// Remove all files from the shared transfer directory.
    static func cleanSharedFiles() {
        guard let dir = sharedFileDirectory else { return }
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for file in files {
                try? fm.removeItem(at: file)
            }
        }
    }
}