// SharedFiles.swift — om-shared lane: Shared tab (chat files via Graph).
//
// Chat files (OneDrive "Microsoft Teams Chat Files" via message attachments)
// and channel files (SharePoint filesFolder) share one list model. Swift
// opens web_url in the browser and saves via core (drive download to
// ~/Downloads); upload posts a reference attachment message (<4 MB).
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
    public typealias OpenURLFn = @Sendable (URL) -> Bool
    public typealias CopyLinkFn = @Sendable (String) -> Void

    @Published public private(set) var files: [SharedFile] = []
    @Published public private(set) var state: SharedFilesState = .loading
    @Published public private(set) var uploading = false
    @Published public private(set) var savingIDs: Set<String> = []
    @Published public private(set) var linkingIDs: Set<String> = []
    @Published public private(set) var links: [String: String] = [:]
    @Published public private(set) var savedPath: String?
    /// Breadcrumb path from root (empty = root). Drives view crumbs + back.
    @Published public private(set) var crumbs: [SharedFolderCrumb] = []
    public private(set) var chatID: String?
    public private(set) var isDemo = false

    /// True at the chat root list (no drill-in). View re-renders via crumbs.
    public var isRoot: Bool { crumbs.isEmpty }

    private let listFetcher: ListFetcher
    private let childrenFetcher: ChildrenFetcher
    private let uploadFetcher: UploadFetcher
    private let downloadFetcher: DownloadFetcher
    private let linkFetcher: LinkFetcher
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
        openURL: @escaping OpenURLFn = SharedFilesStore.defaultOpenURL,
        copyLink: @escaping CopyLinkFn = SharedFilesStore.defaultCopyLink
    ) {
        self.listFetcher = list
        self.childrenFetcher = children
        self.uploadFetcher = upload
        self.downloadFetcher = download
        self.linkFetcher = link
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

    /// Upload a local file (<4 MB core limit) and prepend the result to
    /// the CURRENT level (root or drilled folder). Demo mode fabricates
    /// the row locally.
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
        Task {
            defer { uploading = false }
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

    /// ~/Downloads/<filename> (pure, testable).
    public static func downloadDestination(filename: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent("Downloads/\(filename)")
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

    static func message(for error: Error) -> String {
        if case CoreCallError.failed(let m) = error { return m }
        return String(describing: error)
    }
}

/// Shared-tab file list: rows with Open + Save, Upload + Refresh toolbar.
public struct SharedFilesView: View {
    @ObservedObject public var store: SharedFilesStore

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
            if store.uploading { ProgressView().controlSize(.small) }
            Button("Upload…") { pickAndUpload() }
                .font(.caption)
                .disabled(store.uploading || store.chatID == nil)
                .help("Upload a file (<4 MB) to this chat")
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
                    onOpen: { store.open(file) },
                    onSave: { store.save(file) },
                    onDrill: { store.drill(file) },
                    onLink: { store.shareLink(file) }
                )
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
                if saving {
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
