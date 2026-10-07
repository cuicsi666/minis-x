//
//  SharedFolderVisibility.swift
//  MinisApp
//
//  Shared storage for which top-level subdirs of the FileProvider
//  (shared / skills / memory) should appear in the iOS Files app.
//  Both the main app process and the FileProvider extension read this.
//
//  Backing store: process-local UserDefaults (`.standard`). The App Group
//  suite was removed together with the App Group entitlement, so the main
//  app and the extension no longer share the same backing store (each keeps
//  its own copy — acceptable degradation; visibility still defaults on).
//
//  Semantics:
//    - Default = visible (all three are exposed on first launch).
//    - Toggling an entry off does NOT delete any data — it just hides the
//      subdir from the FileProvider enumerator so iOS Files no longer
//      shows it under "On My iPhone → Minis".
//

import Foundation

enum SharedFolderVisibility {
    /// The three top-level FileProvider subdirs we expose.
    /// Must match FileProviderExtension.topLevelSubdirs.
    static let allFolderNames: [String] = ["shared", "skills", "memory"]

    private static let userDefaultsKeyPrefix = "fileProviderVisible."

    private static var store: UserDefaults {
        // App Group suite is gone; use the process-local standard store.
        .standard
    }

    /// Whether the given folder name (e.g. "shared") is currently visible in Files.
    /// Defaults to `true` if no explicit value has been set.
    static func isVisible(_ name: String) -> Bool {
        let key = userDefaultsKeyPrefix + name
        // If the key doesn't exist, default to visible.
        if store.object(forKey: key) == nil {
            return true
        }
        return store.bool(forKey: key)
    }

    /// Update the visibility for a folder name. Caller is responsible for
    /// asking the FileProvider to re-enumerate afterwards.
    static func setVisible(_ name: String, to visible: Bool) {
        store.set(visible, forKey: userDefaultsKeyPrefix + name)
    }

    /// Names of all currently-visible folders.
    static var visibleFolderNames: Set<String> {
        Set(allFolderNames.filter { isVisible($0) })
    }
}
