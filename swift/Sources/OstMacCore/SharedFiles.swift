// SharedFiles.swift — om-shared lane: Shared tab (chat files via Graph).
//
// Chat files (OneDrive "Microsoft Teams Chat Files" via message attachments)
// and channel files (SharePoint filesFolder) share one list model. Swift
// opens web_url in the browser and saves via core (drive download to
// ~/Downloads); upload posts a reference attachment message (<=4 MB one
// PUT, larger via a resumable session; % polls the core gauge).
//
//   let store = SharedFilesStore()
//   store.open(chatID: "19:...")   // list via core (replaces files)
//   store.drill(folder)            // children via core, crumb pushed
//   store.back()                   // cached parent, no refetch
//   store.upload(path: "/tmp/a.pdf")
//   store.save(file)               // core download to ~/Downloads
// Tests inject mock fetchers (same seam as ChatListViewModel.Fetcher).
import AppKit
import Foundation
import SwiftUI

/// Shared-tab content state.
public enum SharedFilesState: Equatable, Sendable {
    case loading
    case loaded
    case empty
    case error(String)
}

/// One breadcrumb step into a folder (om-iu-foldernav). Root has no crumb.
public struct SharedFolderCrumb: Equatable, Sendable {
    public let driveID: String
    public let itemID: String
    public let name: String

    public init(driveID: String, itemID: String, name: String) {
        self.driveID = driveID
        self.itemID = itemID
        self.name = name
    }

    var key: String { "\(driveID)\n\(itemID)" }
}

@MainActor
public final class SharedFilesStore: ObservableObject {
    public typealias ListFetcher = @Sendable (String, Int32) throws -> SharedFilesResponse
    public typealias ChildrenFetcher = @Sendable (String, String, Int32) throws -> SharedFileChildrenResponse
    public typealias UploadFetcher = @Sendable (String, String) throws -> SharedFileUploadResponse
    public typealias DownloadFetcher = @Sendable (String, String, String) throws -> SharedFileDownloadResponse
    public typealias LinkFetcher = @Sendable (String, String, String) throws -> SharedFileLinkResponse
    public typealias RenameFetcher = @Sendable (String, String, String) throws -> SharedFileManageResponse
    public typealias MoveFetcher = @Sendable (String, String, String) throws -> SharedFileManageResponse
    public typealias CopyFetcher = @Sendable (String, String, String, String?) throws -> SharedFileCopyResponse
    public typealias DeleteFetcher = @Sendable (String, String) throws -> SharedFileDeleteResponse
    public typealias ProgressFetcher = @Sendable () throws -> UploadProgressResponse
    public typealias OpenURLFn = @Sendable (URL) -> Bool
    public typealias CopyLinkFn = @Sendable (String) -> Void

    @Published public private(set) var files: [SharedFile] = []
    @Published public private(set) var state: SharedFilesState = .loading
    @Published public private(set) var uploading = false
    /// 0...1 while an upload streams (nil when idle/unknown; spinner stays).
    @Published public private(set) var uploadProgress: Double?
    @Published public private(set) var savingIDs: Set<String> = []
    @Published public private(set) var linkingIDs: Set<String> = []
    @Published public private(set) var links: [String: String] = [:]
    @Published public private(set) var savedPath: String?
    /// Breadcrumb path from root (empty = root). Drives view crumbs + back.
    @Published public private(set) var crumbs: [SharedFolderCrumb] = []
    @Published public private(set) var managingIDs: Set<String> = []
    public private(set) var chatID: String?
    public private(set) var isDemo = false

    /// True at the chat root list (no drill-in). View re-renders via crumbs.
    public var isRoot: Bool { crumbs.isEmpty }

    private let listFetcher: ListFetcher
    private let childrenFetcher: ChildrenFetcher
    private let uploadFetcher: UploadFetcher
    private let downloadFetcher: DownloadFetcher
    private let linkFetcher: LinkFetcher
    private let renameFetcher: RenameFetcher
    private let moveFetcher: MoveFetcher
    private let copyFetcher: CopyFetcher
    private let deleteFetcher: DeleteFetcher
    private let progressFetcher: ProgressFetcher
    private let openURLFn: OpenURLFn
    /// Per-folder list cache: rootKey + crumb keys. Back/crumb jumps read
    /// here (no refetch); refresh() bypasses for the current level only.
    private var cache: [String: [SharedFile]] = [:]
    private static let rootKey = "root"
    private var currentKey: String { crumbs.last?.key ?? Self.rootKey }
    private let copyLinkFn: CopyLinkFn
    private var openGeneration = 0

    /// Default URL opener. No-op (returns false) under XCTest so tests never
    /// launch the owner's real browser; NSWorkspace.shared.open in production.
    /// Public: Swift requires default-argument callees of a public init to be public.
    public nonisolated static let defaultOpenURL: OpenURLFn = { url in
        if NSClassFromString("XCTestCase") != nil { return false }
        return NSWorkspace.shared.open(url)
    }

    /// Default link copier. No-op under XCTest so tests never touch the
    /// live pasteboard; tests inject a capturing closure instead.
    public nonisolated static let defaultCopyLink: CopyLinkFn = { text in
        if NSClassFromString("XCTestCase") != nil { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    public nonisolated init(
        list: @escaping ListFetcher = {
            try RustCore.sharedFiles(chatID: $0, limit: $1, includeFolders: true)
        },
        children: @escaping ChildrenFetcher = {
            try RustCore.sharedChildren(driveID: $0, itemID: $1, limit: $2)
        },
        upload: @escaping UploadFetcher = { try RustCore.sharedUpload(chatID: $0, path: $1) },
        download: @escaping DownloadFetcher = {
            try RustCore.sharedDownload(driveID: $0, itemID: $1, dest: $2)
        },
        link: @escaping LinkFetcher = {
            try RustCore.sharedLink(driveID: $0, itemID: $1, scope: $2)
        },
        rename: @escaping RenameFetcher = {
            try RustCore.sharedRename(driveID: $0, itemID: $1, newName: $2)
        },
        move: @escaping MoveFetcher = {
            try RustCore.sharedMove(driveID: $0, itemID: $1, destFolderID: $2)
        },
        copy: @escaping CopyFetcher = {
            try RustCore.sharedCopy(driveID: $0, itemID: $1, destFolderID: $2, newName: $3)
        },
        delete: @escaping DeleteFetcher = {
            try RustCore.sharedDelete(driveID: $0, itemID: $1)
        },
        progress: @escaping ProgressFetcher = { try RustCore.sharedUploadProgress() },
        openURL: @escaping OpenURLFn = SharedFilesStore.defaultOpenURL,
        copyLink: @escaping CopyLinkFn = SharedFilesStore.defaultCopyLink
    ) {
        self.listFetcher = list
        self.childrenFetcher = children
        self.uploadFetcher = upload
        self.downloadFetcher = download
        self.linkFetcher = link
        self.renameFetcher = rename
        self.moveFetcher = move
        self.copyFetcher = copy
        self.deleteFetcher = delete
        self.progressFetcher = progress
        self.openURLFn = openURL
        self.copyLinkFn = copyLink
    }

    /// Open a chat/channel: fetch the shared list via core, replace files.
    /// Resets crumbs + cache. Stale completions are dropped (fast
    /// chat-switching lands newest).
    public func open(chatID: String, limit: Int32 = 20) {
        self.chatID = chatID
        crumbs = []
        cache = [:]
        isDemo = false
        state = .loading
        savedPath = nil
        openGeneration += 1
        let gen = openGeneration
        Task {
            let fetcher = listFetcher
            do {
                let resp = try await Task.detached { try fetcher(chatID, limit) }.value
                guard gen == openGeneration else { return }
                cache[Self.rootKey] = resp.files
                files = resp.files
                state = resp.files.isEmpty ? .empty : .loaded
            } catch {
                guard gen == openGeneration else { return }
                state = .error(Self.message(for: error))
            }
        }
    }

    /// Fire-and-forget reload of the CURRENT level (root list or folder
    /// children). Bypasses the cache for this level only.
    public func refresh(limit: Int32 = 20, childrenLimit: Int32 = 50) {
        guard let id = chatID else { return }
        if let crumb = crumbs.last {
            fetchChildren(crumb, limit: childrenLimit)
        } else {
            open(chatID: id, limit: limit)
        }
    }

    /// Drill into a folder row: push crumb, show cached kids or fetch.
    /// No-op for plain files and folders without drive_id (I5 edge: rare
    /// chat-path item, shown as file). Demo mode stays offline (empty).
    public func drill(_ file: SharedFile, limit: Int32 = 50) {
        guard file.isFolder, let drive = file.drive_id else { return }
        let crumb = SharedFolderCrumb(driveID: drive, itemID: file.id, name: file.name)
        crumbs.append(crumb)
        if let hit = cache[crumb.key] {
            files = hit
            state = hit.isEmpty ? .empty : .loaded
            return
        }
        if isDemo {
            files = []
            cache[crumb.key] = []
            state = .empty
            return
        }
        fetchChildren(crumb, limit: limit)
    }

    /// Up one level (no refetch: parents stay cached). No-op at root.
    public func back() {
        guard !crumbs.isEmpty else { return }
        crumbs.removeLast()
        showCurrent()
    }

    /// Breadcrumb jump to depth d (0 = root). No-op unless d < depth.
    public func goTo(depth: Int) {
        let d = max(0, depth)
        guard d < crumbs.count else { return }
        crumbs.removeLast(crumbs.count - d)
        showCurrent()
    }

    public func goToRoot() {
        goTo(depth: 0)
    }

    /// Display the cached list for the current level (back/crumb jumps).
    private func showCurrent() {
        if let hit = cache[currentKey] {
            files = hit
            state = hit.isEmpty ? .empty : .loaded
        } else {
            refresh()
        }
    }

    /// Fetch one folder's children via core (I5 FFI). Late completions
    /// still cache, but only display when still on that folder.
    private func fetchChildren(_ crumb: SharedFolderCrumb, limit: Int32) {
        state = .loading
        savedPath = nil
        openGeneration += 1
        let gen = openGeneration
        Task {
            let fetcher = childrenFetcher
            do {
                let resp = try await Task.detached {
                    try fetcher(crumb.driveID, crumb.itemID, limit)
                }.value
                guard gen == openGeneration else { return }
                cache[crumb.key] = resp.files
                if crumbs.last == crumb {
                    files = resp.files
                    state = resp.files.isEmpty ? .empty : .loaded
                }
            } catch {
                guard gen == openGeneration else { return }
                if crumbs.last == crumb {
                    state = .error(Self.message(for: error))
                }
            }
        }
    }

    /// Demo mode: canned files offline (no core). Resets nav, seeds cache.
    public func showDemo(chatID: String, files: [SharedFile]) {
        self.chatID = chatID
        crumbs = []
        cache = [Self.rootKey: files]
        self.files = files
        isDemo = true
        state = files.isEmpty ? .empty : .loaded
    }

    /// Upload a local file (any size: core routes >4 MB through a
    /// resumable session) and prepend the result to the CURRENT level
    /// (root or drilled folder). While the spinner runs, `%` polls the
    /// core progress gauge. Demo mode fabricates the row locally.
    public func upload(path: String) {
        guard !uploading, let id = chatID else { return }
        if isDemo {
            let name = (path as NSString).lastPathComponent
            files.insert(SharedFile(id: "demo-up-\(files.count + 1)", name: name, size: 1024), at: 0)
            cache[currentKey] = files
            state = .loaded
            return
        }
        uploading = true
        uploadProgress = nil
        let poll = startProgressPoll { [weak self] frac in
            self?.uploadProgress = frac
        }
        Task {
            defer {
                poll.cancel()
                uploading = false
                uploadProgress = nil
            }
            let fetcher = uploadFetcher
            do {
                let resp = try await Task.detached { try fetcher(id, path) }.value
                files = Self.upsert(resp.file, into: files)
                cache[currentKey] = files
                state = .loaded
            } catch {
                state = .error(Self.message(for: error))
            }
        }
    }

    /// Poll the core gauge every 200 ms until cancelled (upload %).
    /// The closure runs on the main actor; throwers keep the last value.
    func startProgressPoll(onTick: @escaping @MainActor (Double?) -> Void) -> Task<Void, Never> {
        let fetcher = progressFetcher
        return Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if Task.isCancelled { break }
                if let p = try? await Task.detached { try fetcher() }.value {
                    await onTick(Self.progressFraction(uploaded: p.uploaded, total: p.total))
                }
            }
        }
    }

    /// Open the SharePoint page in the browser. No-op without a web_url.
    /// Returns the URL opened, if any (test seam).
    @discardableResult
    public func open(_ file: SharedFile) -> URL? {
        guard let s = file.web_url, let url = URL(string: s) else { return nil }
        _ = openURLFn(url)
        return url
    }

    /// Save via core drive download to ~/Downloads. Needs drive_id; without
    /// it falls back to opening the pre-signed download_url in the browser.
    /// Returns the destination path (core path) or nil for browser fallback.
    public func save(_ file: SharedFile) {
        if let drive = file.drive_id {
            guard !savingIDs.contains(file.id) else { return }
            savingIDs.insert(file.id)
            let dest = Self.downloadDestination(filename: file.name)
            let fetcher = downloadFetcher
            let itemID = file.id
            Task {
                defer { savingIDs.remove(itemID) }
                do {
                    let resp = try await Task.detached {
                        try fetcher(drive, itemID, dest)
                    }.value
                    savedPath = resp.path
                } catch {
                    state = .error(Self.message(for: error))
                }
            }
        } else if let s = file.download_url, let url = URL(string: s) {
            _ = openURLFn(url) // browser downloads the pre-signed URL
        }
    }

    /// Cached sharing link for one file (createLink result, or the
    /// row's own share_url when core filled it). Nil until linked.
    public func link(for file: SharedFile) -> String? {
        links[file.id] ?? file.share_url
    }

    /// Create a view-only sharing link via core and copy it to the
    /// pasteboard (injected writer). Cached links re-copy without
    /// refetching (createLink is idempotent server-side anyway).
    /// No-op without a drive_id; demo mode fabricates a stable link.
    public func shareLink(_ file: SharedFile, scope: String = "organization") {
        if let cached = link(for: file) {
            copyLinkFn(cached)
            return
        }
        guard let drive = file.drive_id else { return }
        if isDemo {
            let demo = SharedFileLink.demoLink(for: file.id)
            links[file.id] = demo
            files = files.map { $0.id == file.id ? $0.withShareURL(demo) : $0 }
            copyLinkFn(demo)
            return
        }
        guard !linkingIDs.contains(file.id) else { return }
        linkingIDs.insert(file.id)
        let fetcher = linkFetcher
        let itemID = file.id
        Task {
            defer { linkingIDs.remove(itemID) }
            do {
                let resp = try await Task.detached {
                    try fetcher(drive, itemID, scope)
                }.value
                links[itemID] = resp.link
                files = files.map { $0.id == itemID ? $0.withShareURL(resp.link) : $0 }
                copyLinkFn(resp.link)
            } catch {
                state = .error(Self.message(for: error))
            }
        }
    }

    // MARK: - om-i3-manage: rename/move/copy/delete

    /// Rename via core PATCH. Demo mode renames the row locally.
    /// No-op without a drive_id (offline rows) or when blank/unchanged.
    public func rename(_ file: SharedFile, to newName: String) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != file.name, !managingIDs.contains(file.id) else { return }
        if isDemo {
            files = Self.renamed(file.id, to: name, in: files)
            return
        }
        guard let drive = file.drive_id else { return }
        managingIDs.insert(file.id)
        let fetcher = renameFetcher
        let itemID = file.id
        Task {
            defer { managingIDs.remove(itemID) }
            do {
                let resp = try await Task.detached {
                    try fetcher(drive, itemID, name)
                }.value
                files = Self.upsert(resp.file, into: files)
            } catch {
                state = .error(Self.message(for: error))
            }
        }
    }

    /// Move to another folder (same drive) via core PATCH. Demo mode is a
    /// no-op: the row stays (no folder model offline).
    public func move(_ file: SharedFile, toFolder destFolderID: String) {
        let folder = destFolderID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !folder.isEmpty, !isDemo, !managingIDs.contains(file.id) else { return }
        guard let drive = file.drive_id else { return }
        managingIDs.insert(file.id)
        let fetcher = moveFetcher
        let itemID = file.id
        Task {
            defer { managingIDs.remove(itemID) }
            do {
                let resp = try await Task.detached {
                    try fetcher(drive, itemID, folder)
                }.value
                files = Self.upsert(resp.file, into: files)
            } catch {
                state = .error(Self.message(for: error))
            }
        }
    }

    /// Copy to another folder (same drive, async server-side). The copy
    /// lands outside this list, so the row list is untouched; callers
    /// refresh to see server-side effects. Demo mode is a no-op.
    public func copy(_ file: SharedFile, toFolder destFolderID: String, newName: String? = nil) {
        let folder = destFolderID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !folder.isEmpty, !isDemo, !managingIDs.contains(file.id) else { return }
        guard let drive = file.drive_id else { return }
        managingIDs.insert(file.id)
        let fetcher = copyFetcher
        let itemID = file.id
        let name = newName?.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            defer { managingIDs.remove(itemID) }
            do {
                _ = try await Task.detached {
                    try fetcher(drive, itemID, folder, name)
                }.value
            } catch {
                state = .error(Self.message(for: error))
            }
        }
    }

    /// Delete via core DELETE. Demo mode removes the row locally.
    /// Without a drive_id there is nothing server-side to delete: the row
    /// is dropped locally so the list still reflects the user's intent.
    public func delete(_ file: SharedFile) {
        guard !managingIDs.contains(file.id) else { return }
        guard let drive = file.drive_id, !isDemo else {
            files = Self.removed(file.id, from: files)
            if files.isEmpty { state = .empty }
            return
        }
        managingIDs.insert(file.id)
        let fetcher = deleteFetcher
        let itemID = file.id
        Task {
            defer { managingIDs.remove(itemID) }
            do {
                let resp = try await Task.detached {
                    try fetcher(drive, itemID)
                }.value
                files = Self.removed(resp.id, from: files)
                if files.isEmpty { state = .empty }
            } catch {
                state = .error(Self.message(for: error))
            }
        }
    }

    /// ~/Downloads/<filename> (pure, testable).
    public static func downloadDestination(filename: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent("Downloads/\(filename)")
    }

    /// Gauge bytes → 0...1 fraction (nil while the total is unknown;
    /// over-report clamps to 1). Pure, testable.
    public static func progressFraction(uploaded: UInt64, total: UInt64) -> Double? {
        guard total > 0 else { return nil }
        return min(1.0, Double(uploaded) / Double(total))
    }

    /// Pure upsert: same id replaces in place, new id prepends (newest first).
    public static func upsert(_ file: SharedFile, into list: [SharedFile]) -> [SharedFile] {
        var out = list
        if let i = out.firstIndex(where: { $0.id == file.id }) {
            out[i] = file
        } else {
            out.insert(file, at: 0)
        }
        return out
    }

    /// Pure remove: drops `id`, keeps order (delete path).
    public static func removed(_ id: String, from list: [SharedFile]) -> [SharedFile] {
        list.filter { $0.id != id }
    }

    /// Pure local rename (demo mode): swaps the name, keeps the row in place.
    public static func renamed(_ id: String, to name: String, in list: [SharedFile]) -> [SharedFile] {
        list.map { f in
            guard f.id == id else { return f }
            return SharedFile(
                id: f.id, name: name, size: f.size, mime: f.mime,
                web_url: f.web_url, download_url: f.download_url,
                drive_id: f.drive_id, created: f.created, modified: f.modified,
                sender: f.sender, attachment_id: f.attachment_id)
        }
    }

    static func message(for error: Error) -> String {
        if case CoreCallError.failed(let m) = error { return m }
        return String(describing: error)
    }
}

/// Shared-tab file list: rows with Open + Save, Upload + Refresh toolbar.
public struct SharedFilesView: View {
    @ObservedObject public var store: SharedFilesStore
    @State private var renameTarget: SharedFile?
    @State private var renameName = ""
    @State private var moveTarget: SharedFile?
    @State private var moveFolder = ""
    @State private var copyTarget: SharedFile?
    @State private var copyFolder = ""
    @State private var copyName = ""
    @State private var deleteTarget: SharedFile?

    public init(store: SharedFilesStore) {
        self.store = store
    }

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if !store.isRoot { breadcrumbs }
            if !store.isRoot { Divider() }
            content
        }
        .sheet(item: $renameTarget) { file in
            renameSheet(file)
        }
        .sheet(item: $moveTarget) { file in
            folderSheet(
                title: "Move “\(file.name)”",
                folder: $moveFolder,
                actionLabel: "Move"
            ) {
                store.move(file, toFolder: moveFolder)
                moveTarget = nil
            }
        }
        .sheet(item: $copyTarget) { file in
            VStack(spacing: 12) {
                Text("Copy “\(file.name)”").font(.headline)
                TextField("Destination folder id", text: $copyFolder)
                    .textFieldStyle(.roundedBorder)
                TextField("New name (optional)", text: $copyName)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("Cancel") { copyTarget = nil }.keyboardShortcut(.cancelAction)
                    Button("Copy") {
                        store.copy(
                            file, toFolder: copyFolder,
                            newName: copyName.isEmpty ? nil : copyName)
                        copyTarget = nil
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(copyFolder.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding()
            .frame(minWidth: 320)
        }
        .alert(item: $deleteTarget) { file in
            Alert(
                title: Text("Delete “\(file.name)”?"),
                message: Text("This removes the file from the shared library. This cannot be undone."),
                primaryButton: .destructive(Text("Delete")) {
                    store.delete(file)
                },
                secondaryButton: .cancel()
            )
        }
    }

    private func renameSheet(_ file: SharedFile) -> some View {
        VStack(spacing: 12) {
            Text("Rename “\(file.name)”").font(.headline)
            TextField("New name", text: $renameName)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { renameTarget = nil }.keyboardShortcut(.cancelAction)
                Button("Rename") {
                    store.rename(file, to: renameName)
                    renameTarget = nil
                }
                .keyboardShortcut(.defaultAction)
                .disabled(renameName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 300)
    }

    private func folderSheet(
        title: String,
        folder: Binding<String>,
        actionLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 12) {
            Text(title).font(.headline)
            TextField("Destination folder id", text: folder)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { moveTarget = nil }.keyboardShortcut(.cancelAction)
                Button(actionLabel, action: action)
                    .keyboardShortcut(.defaultAction)
                    .disabled(folder.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 300)
    }

    /// Back + breadcrumb trail (root "Files" + folder crumbs). Depth jumps
    /// read the store cache (no refetch).
    private var breadcrumbs: some View {
        HStack(spacing: 4) {
            Button("‹ Back") { store.back() }
                .font(.caption)
                .buttonStyle(.link)
            Text("·").foregroundStyle(.secondary)
            Button("Files") { store.goToRoot() }
                .font(.caption)
                .buttonStyle(.link)
            ForEach(Array(store.crumbs.enumerated()), id: \.offset) { i, crumb in
                Text("/").foregroundStyle(.secondary).font(.caption)
                if i == store.crumbs.count - 1 {
                    Text(crumb.name)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                } else {
                    Button(crumb.name) { store.goTo(depth: i + 1) }
                        .font(.caption)
                        .buttonStyle(.link)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    private var toolbar: some View {
        HStack {
            Text("\(store.files.count) items")
                .font(.caption).monospaced()
                .foregroundStyle(.secondary)
            if let saved = store.savedPath {
                Text("saved \(saved)")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
            Spacer()
            if store.uploading {
                if let frac = store.uploadProgress {
                    Text("\(Int((frac * 100).rounded()))%")
                        .font(.caption).monospaced()
                        .foregroundStyle(.secondary)
                }
                ProgressView().controlSize(.small)
            }
            Button("Upload…") { pickAndUpload() }
                .font(.caption)
                .disabled(store.uploading || store.chatID == nil)
                .help("Upload a file to this chat (large files use resumable upload)")
            Button("Refresh") { store.refresh() }
                .font(.caption)
                .disabled(store.chatID == nil)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .loading:
            VStack {
                Spacer()
                ProgressView("Loading shared files…")
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "folder")
                    .font(.largeTitle).foregroundStyle(.secondary)
                Text(store.isRoot ? "No shared files yet." : "This folder is empty.")
                    .font(.headline)
                Text(store.isRoot ? "Files shared in this conversation appear here." : "Files in this folder appear here.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .error(message):
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle).foregroundStyle(.orange)
                Text(message)
                    .font(.callout).foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .padding(.horizontal)
                Button("Retry") { store.refresh() }
                    .buttonStyle(.bordered)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            List(store.files) { file in
                SharedFileRow(
                    file: file,
                    saving: store.savingIDs.contains(file.id),
                    linking: store.linkingIDs.contains(file.id),
                    linked: store.link(for: file) != nil,
                    managing: store.managingIDs.contains(file.id),
                    onOpen: { store.open(file) },
                    onSave: { store.save(file) },
                    onDrill: { store.drill(file) },
                    onLink: { store.shareLink(file) }
                )
                // MARK: - om-i3-manage row context menu
                .contextMenu {
                    // MARK: om-i3-manage region
                    Button("Rename…") {
                        renameName = file.name
                        renameTarget = file
                    }
                    .disabled(file.drive_id == nil && !store.isDemo)
                    Button("Move to Folder…") {
                        moveFolder = ""
                        moveTarget = file
                    }
                    .disabled(file.drive_id == nil)
                    Button("Copy to Folder…") {
                        copyFolder = ""
                        copyName = ""
                        copyTarget = file
                    }
                    .disabled(file.drive_id == nil)
                    Divider()
                    Button("Delete…", role: .destructive) {
                        deleteTarget = file
                    }
                    // end om-i3-manage region
                }
            }
            .listStyle(.plain)
        }
    }

    private func pickAndUpload() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            store.upload(path: url.path)
        }
    }
}

struct SharedFileRow: View {
    let file: SharedFile
    var saving: Bool = false
    var linking: Bool = false
    var linked: Bool = false
    var managing: Bool = false
    var onOpen: () -> Void = {}
    var onSave: () -> Void = {}
    var onDrill: () -> Void = {}
    var onLink: () -> Void = {}

    /// Folders drill in (no Open/Save: never downloadable per I5). Folders
    /// without drive_id render as plain file rows (no drill target).
    private var drillable: Bool { file.isFolder && file.drive_id != nil }

    var body: some View {
        if drillable {
            HStack(spacing: 10) {
                Image(systemName: "folder")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name)
                        .font(.body)
                        .lineLimit(1)
                        .textSelection(.enabled)
                    Text("Folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onTapGesture(perform: onDrill)
        } else {
            HStack(spacing: 10) {
                Image(systemName: file.isFolder ? "folder" : file.iconName)
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name)
                        .font(.body)
                        .lineLimit(1)
                        .textSelection(.enabled)
                    HStack(spacing: 6) {
                        Text(file.sizeLabel)
                            .font(.caption).monospaced()
                            .foregroundStyle(.secondary)
                        if let sender = file.sender {
                            Text("· \(sender)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                Spacer()
                if saving || managing {
                    ProgressView().controlSize(.small)
                } else {
                    if file.web_url != nil {
                        Button("Open", action: onOpen)
                            .buttonStyle(.link)
                            .font(.caption)
                            .help("Open in SharePoint (browser)")
                    }
                    if file.drive_id != nil || file.download_url != nil {
                        Button("Save", action: onSave)
                            .buttonStyle(.link)
                            .font(.caption)
                            .help("Save to ~/Downloads")
                    }
                    if file.drive_id != nil {
                        SharedFileLinkButton(linking: linking, linked: linked, onTap: onLink)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
}
