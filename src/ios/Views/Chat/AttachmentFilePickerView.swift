//
//  AttachmentFilePickerView.swift
//  MinisApp
//
//  In-app attachment file browser that picks files WITHOUT the system
//  UIDocumentPicker / fileImporter. On sideloaded (全能签) installs the system
//  document picker returns URLs whose security-scoped access
//  (startAccessingSecurityScopedResource) silently fails, so the picked file
//  cannot actually be read. Photos still work because they go through the
//  system PhotosPicker, but ordinary files are unreadable.
//
//  This view browses paths inside the app sandbox directly — the iSH rootfs
//  (RootfsManager.shared.rootfsPath) and its standard subdirectories
//  (var/minis/workspace, shared, attachments if present) — which require no
//  security scope and are always readable via plain FileManager calls
//  (contentsOfDirectory(at:includingPropertiesForKeys:) / copyItem).
//
//  Selection model:
//    * tapping a directory navigates into it
//    * tapping a file toggles it into the selection set (highlighted)
//    * "Add (N)" calls back with the selected URLs
//
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Row entry

/// One directory or file inside the sandbox when browsing.
private struct AttachmentFileEntry: Identifiable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let size: Int64

    var id: URL { url }
}

// MARK: - Quick-access root

/// A pinned directory shortcut shown as a chip so the user can jump straight
/// to a standard folder (iSH root, var/minis, workspace, shared, attachments).
private struct AttachmentRootShortcut: Identifiable, Hashable {
    let url: URL
    let label: String
    let systemImage: String
    var id: URL { url }
}

// MARK: - Main view

struct AttachmentFilePickerView: View {
    @Environment(\.dismiss) private var dismiss

    /// Called with the read-accessible URLs the user selected. The owning
    /// screen is responsible for handing them to
    /// `addFileAttachment(from:)` so they get copied into the attachment
    /// cache and attached.
    let onSelect: ([URL]) -> Void

    /// The sandbox root the browser starts from. Defaults to the iSH rootfs.
    private let rootURL: URL
    /// Pinned quick-access shortcuts under the root.
    private let shortcuts: [AttachmentRootShortcut]

    // Current directory + its breadcrumb components (relative to rootLabel).
    @State private var currentDirectory: URL
    @State private var breadcrumbs: [URL] = []

    @State private var entries: [AttachmentFileEntry] = []
    @State private var selection: Set<URL> = []
    @State private var loadFailed = false
    @State private var isShowingQuickNav = false

    // MARK: Init

    init(root: URL? = nil, onSelect: @escaping ([URL]) -> Void) {
        let r = root ?? RootfsManager.shared.rootfsPath
        self.rootURL = r
        self.onSelect = onSelect
        self._currentDirectory = State(initialValue: r)
        self._breadcrumbs = State(initialValue: [])

        // Quick-access shortcuts, skipping any that do not exist yet.
        let fm = FileManager.default
        var found: [AttachmentRootShortcut] = []
        func addIfDirectory(_ url: URL, _ label: String, _ image: String) {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                found.append(AttachmentRootShortcut(url: url, label: label, systemImage: image))
            }
        }
        addIfDirectory(r, "iSH Root", "internaldrive")
        let varMinis = RootfsManager.shared.dataPath.appendingPathComponent("var/minis")
        addIfDirectory(varMinis, "Minis", "folder")
        addIfDirectory(varMinis.appendingPathComponent("workspace"), "workspace", "hammer")
        addIfDirectory(varMinis.appendingPathComponent("shared"), "shared", "person.2")
        addIfDirectory(varMinis.appendingPathComponent("attachments"), "attachments", "paperclip")
        self.shortcuts = found
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                quickNavBar
                pathBar
                content
            }
            .navigationTitle("Add Attachment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        finishPicking()
                    } label: {
                        Text("Add (\(selection.count))")
                            .fontWeight(.semibold)
                    }
                    .disabled(selection.isEmpty)
                }
            }
            .onAppear { loadCurrentDirectory() }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: Quick navigation chips

    private var quickNavBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(shortcuts) { shortcut in
                    Button {
                        navigate(quick: shortcut.url)
                    } label: {
                        Label(shortcut.label, systemImage: shortcut.systemImage)
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                (currentDirectory == shortcut.url || currentDirectory.path.hasPrefix(shortcut.url.path + "/"))
                                    ? Color.accentColor.opacity(0.15)
                                    : Color(UIColor.tertiarySystemFill)
                            )
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
        .background(Color(UIColor.secondarySystemBackground))
    }

    // MARK: Path bar / breadcrumb

    private var pathBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                // Root button
                Button {
                    navigateTo(url: rootURL)
                } label: {
                    Image(systemName: "internaldrive")
                        .font(.caption)
                        .foregroundColor(.blue)
                        .padding(.trailing, 2)
                }
                if !breadcrumbs.isEmpty {
                    ForEach(breadcrumbs.indices, id: \.self) { index in
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Button {
                            let target = Array(breadcrumbs.prefix(index + 1)).last ?? rootURL
                            navigateTo(url: target)
                        } label: {
                            Text(breadcrumbs[index].lastPathComponent)
                                .font(.caption)
                                .foregroundColor(.blue)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(Color(UIColor.secondarySystemBackground))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(UIColor.separator)).frame(height: 0.5)
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if loadFailed {
            Spacer()
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 40))
                    .foregroundColor(.secondary)
                Text("This folder could not be read.")
                    .foregroundColor(.secondary)
            }
            Spacer()
        } else if entries.isEmpty {
            Spacer()
            VStack(spacing: 12) {
                Image(systemName: "folder")
                    .font(.system(size: 48))
                    .foregroundColor(.secondary)
                Text("Empty folder")
                    .foregroundColor(.secondary)
            }
            Spacer()
        } else {
            List {
                ForEach(entries) { item in
                    row(item)
                }
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder
    private func row(_ item: AttachmentFileEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: iconName(for: item))
                .font(.system(size: 22))
                .foregroundColor(item.isDirectory ? Color.accentColor : .secondary)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.body)
                    .lineLimit(1)
                    .foregroundColor(.primary)
                if !item.isDirectory {
                    Text(formattedSize(item.size))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            if item.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Image(systemName: selection.contains(item.url) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundColor(selection.contains(item.url) ? .accentColor : .secondary)
            }
        }
        .contentShape(Rectangle())
        .background(selection.contains(item.url) ? Color.accentColor.opacity(0.12) : Color.clear)
        .onTapGesture {
            if item.isDirectory {
                navigateTo(url: item.url)
            } else {
                toggleSelection(item.url)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(item.isDirectory
                            ? "Opens this folder"
                            : (selection.contains(item.url) ? "Selected" : "Selects this file"))
    }

    // MARK: - Navigation & loading

    private func navigate(quick url: URL) {
        // Recompute breadcrumbs up to the root as the URL for each level.
        breadcrumbs = breadcrumbURLs(for: url)
        currentDirectory = url
        selection.removeAll()
        loadCurrentDirectory()
    }

    private func navigateTo(url: URL) {
        // Normalize under root support.
        breadcrumbs = breadcrumbURLs(for: url)
        currentDirectory = url
        selection.removeAll()
        loadCurrentDirectory()
    }

    /// Build the breadcrumb URLs (each ancestor, root first) for a directory.
    private func breadcrumbURLs(for url: URL) -> [URL] {
        var result: [URL] = []
        if url == rootURL { return [] }
        let root = rootURL.path
        guard url.path.hasPrefix(root) else { return [url] }
        let rel = String(url.path.dropFirst(root.count))
        var cursor = rootURL
        for comp in rel.split(separator: "/") {
            cursor = cursor.appendingPathComponent(String(comp))
            result.append(cursor)
        }
        return result
    }


    private func loadCurrentDirectory() {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .isHiddenKey]
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: currentDirectory.path, isDirectory: &isDir), isDir.boolValue else {
            loadFailed = true
            entries = []
            return
        }

        do {
            let urls = try fm.contentsOfDirectory(at: currentDirectory,
                                                  includingPropertiesForKeys: keys,
                                                  options: [.skipsHiddenFiles])
            var items: [AttachmentFileEntry] = []
            for url in urls {
                var itemIsDir: ObjCBool = false
                fm.fileExists(atPath: url.path, isDirectory: &itemIsDir)
                let isDirBool = itemIsDir.boolValue
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                items.append(AttachmentFileEntry(url: url,
                                                 name: url.lastPathComponent,
                                                 isDirectory: isDirBool,
                                                 size: Int64(size)))
            }
            // Directories first, then alphabetically by name.
            items.sort {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            entries = items
            loadFailed = false
        } catch {
            loadFailed = true
            entries = []
        }
    }

    private func toggleSelection(_ url: URL) {
        if selection.contains(url) {
            selection.remove(url)
        } else {
            selection.insert(url)
        }
    }

    private func finishPicking() {
        guard !selection.isEmpty else { return }
        // Stable ordering so repeated picks feel predictable.
        let ordered = selection.sorted { $0.lastPathComponent < $1.lastPathComponent }
        onSelect(Array(ordered))
        dismiss()
    }

    // MARK: - Icon / size helpers

    private func iconName(for item: AttachmentFileEntry) -> String {
        if item.isDirectory { return "folder.fill" }
        switch item.name.lowercased() {
        case let name where name.hasSuffix(".pdf"): return "doc.richtext"
        case let name where ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tiff"]
            .contains(where: { name.hasSuffix(".\($0)") }): return "photo"
        case let name where ["mp4", "mov", "m4v", "avi", "mkv", "webm"]
            .contains(where: { name.hasSuffix(".\($0)") }): return "video"
        case let name where ["mp3", "m4a", "wav", "aac", "flac", "ogg"]
            .contains(where: { name.hasSuffix(".\($0)") }): return "waveform"
        case let name where ["zip", "tar", "gz", "bz2", "7z", "rar"]
            .contains(where: { name.hasSuffix(".\($0)") }): return "archivebox"
        default: return "doc.text"
        }
    }

    private func formattedSize(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB, .useBytes]
        return f.string(fromByteCount: bytes)
    }
}