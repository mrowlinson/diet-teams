// SharedFiles.swift — om-shared lane: Shared tab (chat files via Graph).
//
// Chat files (OneDrive "Microsoft Teams Chat Files" via message attachments)
// and channel files (SharePoint filesFolder) share one list model. Swift
// opens web_url in the browser and saves via core (drive download, Save-as
// panel defaulting to ~/Downloads/<name>); upload posts a reference
// attachment message (<=4 MB one PUT, larger via a resumable session;
// % polls the core gauge; multi-upload pre-gated like the composer).
//
//   let store = SharedFilesStore()
//   store.open(chatID: "19:...")   // list via core (replaces files)
//   store.drill(folder)            // children via core, crumb pushed
//   store.back()                   // cached parent, no refetch
//   store.upload(paths: urls.map(\.path)) // multi-upload, cap-gated
//   store.save(file)               // core download to ~/Downloads
//   store.saveAs(file, to: panel.url!.path)
//   store.displayedFiles           // filter + sort applied
// Tests inject mock fetchers (same seam as ChatListViewModel.Fetcher).
import AppKit
import DietDesign
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

/// Shared-tab sort orders (om-iu-rowdepth): name A→Z (case-insensitive),
/// date newest-first, size largest-first. Ties break by id (deterministic).
public enum SharedFilesSort: String, CaseIterable, Sendable {
    case name
    case date
    case size

    public var label: String { rawValue.capitalized }
}

/// Shared-tab type filter chips (om-iu-rowdepth). Mirrors the
/// `SharedFile.iconName` mime/extension mapping; anything outside the four
/// kinds (archives, audio, video, unknown) lands in `.other`.
public enum SharedFilesTypeFilter: String, CaseIterable, Sendable {
    case all
    case docs
    case images
    case sheets
    case slides
    case other

    public var label: String {
        switch self {
        case .all: return "All"
        case .docs: return "Docs"
        case .images: return "Images"
        case .sheets: return "Sheets"
        case .slides: return "Slides"
        case .other: return "Other"
        }
    }

    public func matches(_ file: SharedFile) -> Bool {
        switch self {
        case .all: return true
        case .docs: return Self.kind(of: file) == .docs
        case .images: return Self.kind(of: file) == .images
        case .sheets: return Self.kind(of: file) == .sheets
        case .slides: return Self.kind(of: file) == .slides
        case .other: return Self.kind(of: file) == .other
        }
    }

    private static func kind(of file: SharedFile) -> SharedFilesTypeFilter {
        let m = (file.mime ?? "").lowercased()
        let ext = (file.name as NSString).pathExtension.lowercased()
        if m.hasPrefix("image/")
            || ["png", "jpg", "jpeg", "gif", "heic", "webp"].contains(ext)
        {
            return .images
        }
        if m.hasPrefix("text/") || m == "application/pdf"
            || m.contains("msword") || m.contains("wordprocessingml")
            || m.contains("rtf")
            || ["pdf", "doc", "docx", "pages", "txt", "md", "rtf"].contains(ext)
        {
            return .docs
        }
        if m.contains("spreadsheet") || m.contains("sheet")
            || m.contains("excel") || m.contains("csv")
            || ["xls", "xlsx", "numbers", "csv"].contains(ext)
        {
            return .sheets
        }
        if m.contains("presentation") || m.contains("powerpoint")
            || m.contains("keynote")
            || ["ppt", "pptx", "key"].contains(ext)
        {
            return .slides
        }
        return .other
    }
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
    /// File-size probe (bytes), nil when unreadable (stages as 0 B).
    /// Same seam as the composer (om-iu-rowdepth pre-gate).
    public typealias SizeProbe = ComposeAttachmentsStore.SizeProbe

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
    /// Paths skipped by the 4 MB pre-gate on the last upload call.
    @Published public private(set) var gatedUploads: [String] = []
    /// Cap message for the last gated upload (composer wording).
    @Published public private(set) var uploadError: String?
    /// Sort + type filter (bound to the toolbar controls).
    @Published public var sort: SharedFilesSort = .date
    @Published public var filter: SharedFilesTypeFilter = .all
    /// Drop queue (om-iu-dropquick): multi-file drops upload one at a
    /// time, in drop order; the picker path enqueues a single path.
    private var uploadQueue: [String] = []
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
    /// Per-chat root cache (om-fix-tabs): reopening a chat shows its rows
    /// instantly, then refreshes behind (tab switch never waits).
    private var chatCache: [String: [SharedFile]] = [:]
    private static let rootKey = "root"
    private var currentKey: String { crumbs.last?.key ?? Self.rootKey }
    private let copyLinkFn: CopyLinkFn
    private let sizeProbe: SizeProbe
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
        copyLink: @escaping CopyLinkFn = SharedFilesStore.defaultCopyLink,
        sizeProbe: @escaping SizeProbe = ComposeAttachmentsStore.defaultSizeProbe
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
        self.sizeProbe = sizeProbe
    }

    /// Files after the type filter + sort (what the list renders).
    public var displayedFiles: [SharedFile] {
        Self.displayed(files, sort: sort, filter: filter)
    }

    /// Open a chat/channel: fetch the shared list via core, replace files.
    /// Resets crumbs + cache. Stale completions are dropped (fast
    /// chat-switching lands newest). Cache hit: rows show instantly and
    /// the fetch refreshes behind (no spinner flash, no blank).
    public func open(chatID: String, limit: Int32 = 20) {
        stashRoot()
        self.chatID = chatID
        crumbs = []
        cache = [:]
        isDemo = false
        savedPath = nil
        openGeneration += 1
        let gen = openGeneration
        if let hit = chatCache[chatID] {
            cache[Self.rootKey] = hit
            files = hit
            state = hit.isEmpty ? .empty : .loaded
        } else {
            files = []
            state = .loading
        }
        Task {
            let fetcher = listFetcher
            do {
                let resp = try await Task.detached { try fetcher(chatID, limit) }.value
                guard gen == openGeneration else { return }
                cache[Self.rootKey] = resp.files
                chatCache[chatID] = resp.files
                files = resp.files
                state = resp.files.isEmpty ? .empty : .loaded
            } catch {
                guard gen == openGeneration else { return }
                // Background-refresh failure keeps cached rows on screen;
                // the error only blanks when data is truly absent.
                if files.isEmpty {
                    state = .error(Self.message(for: error))
                }
            }
        }
    }

    /// Stash the outgoing chat's root list for instant revisit. Live rows
    /// win at root (manage ops mutate `files`, not the folder cache).
    private func stashRoot() {
        guard let old = chatID else { return }
        if isRoot {
            chatCache[old] = files
        } else if let root = cache[Self.rootKey] {
            chatCache[old] = root
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
        stashRoot()
        self.chatID = chatID
        crumbs = []
        cache = [Self.rootKey: files]
        chatCache[chatID] = files
        self.files = files
        isDemo = true
        state = files.isEmpty ? .empty : .loaded
    }

    /// Upload one local file (single-file convenience over `upload(paths:)`).
    public func upload(path: String) {
        upload(paths: [path])
    }

    /// Multi-upload (om-iu-rowdepth pre-gate + om-iu-dropquick queue):
    /// probe every path, pre-gate over-cap files into
    /// `gatedUploads`/`uploadError` (the fetcher is never called for
    /// them), then enqueue the rest in pick order. Uploads run one at
    /// a time via `drainUploadQueue` (re-entrant: drops arriving
    /// mid-upload wait their turn); each result upserts into the
    /// CURRENT level. Failures mark `state` but don't stop later
    /// files. Demo mode fabricates each row locally.
    public func upload(paths: [String]) {
        guard !paths.isEmpty, chatID != nil else { return }
        var ok: [String] = []
        var gated: [(path: String, size: UInt64)] = []
        for path in paths {
            let size = sizeProbe(path) ?? 0
            if ComposeAttachments.isTooLarge(size: size) {
                gated.append((path, size))
            } else {
                ok.append(path)
            }
        }
        gatedUploads = gated.map(\.path)
        if let first = gated.first {
            var msg = ComposeAttachments.capMessage(actual: first.size)
            if gated.count > 1 { msg += " (+\(gated.count - 1) more)" }
            uploadError = msg
        } else {
            uploadError = nil
        }
        guard !ok.isEmpty else { return }
        if isDemo {
            for path in ok {
                let name = (path as NSString).lastPathComponent
                files.insert(
                    SharedFile(id: "demo-up-\(files.count + 1)", name: name, size: 1024),
                    at: 0)
            }
            cache[currentKey] = files
            state = .loaded
            return
        }
        uploadQueue.append(contentsOf: ok)
        drainUploadQueue()
    }

    /// Upload the head of the queue, then the rest in order. Re-entrant:
    /// drops arriving mid-upload wait their turn instead of dropping.
    /// The `%` gauge polls while each upload streams.
    private func drainUploadQueue() {
        guard !uploading, let id = chatID, !uploadQueue.isEmpty else { return }
        uploading = true
        uploadProgress = nil
        let poll = startProgressPoll { [weak self] frac in
            self?.uploadProgress = frac
        }
        let path = uploadQueue.removeFirst()
        Task {
            defer {
                poll.cancel()
                uploading = false
                uploadProgress = nil
                drainUploadQueue()
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

    /// Dismiss the over-cap upload banner.
    public func clearUploadError() {
        uploadError = nil
        gatedUploads = []
    }

    /// Open the SharePoint page in the browser. No-op without a web_url.
    /// Returns the URL opened, if any (test seam).
    @discardableResult
    public func open(_ file: SharedFile) -> URL? {
        guard let s = file.web_url, let url = URL(string: s) else { return nil }
        _ = openURLFn(url)
        return url
    }

    /// Quick save via core drive download to ~/Downloads/<name>.
    /// The view prefers `saveAs` (NSSavePanel defaulting there).
    public func save(_ file: SharedFile) {
        saveAs(file, to: Self.downloadDestination(filename: file.name))
    }

    /// Save via core drive download to an explicit destination (the Save-as
    /// panel's pick). Needs drive_id; without it falls back to opening the
    /// pre-signed download_url in the browser (dest unused).
    public func saveAs(_ file: SharedFile, to dest: String) {
        if let drive = file.drive_id {
            guard !savingIDs.contains(file.id) else { return }
            savingIDs.insert(file.id)
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

    /// Save-as panel default directory: ~/Downloads (pure, testable).
    public static func saveAsDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads")
    }

    /// Save-as panel default filename: the shared name, verbatim.
    public static func saveAsName(for file: SharedFile) -> String {
        file.name
    }

    /// Full Save-as default: ~/Downloads/<name>.
    public static func saveAsDestination(for file: SharedFile) -> String {
        downloadDestination(filename: file.name)
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
                sender: f.sender, attachment_id: f.attachment_id,
                is_folder: f.is_folder, share_url: f.share_url)
        }
    }

    private static let isoDate: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let isoDateFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Sort key: modified, else created, else nil (sorts last under .date).
    public static func dateValue(_ file: SharedFile) -> Date? {
        for raw in [file.modified, file.created].compactMap({ $0 }) {
            if let d = isoDate.date(from: raw) ?? isoDateFrac.date(from: raw) {
                return d
            }
        }
        return nil
    }

    /// Pure sort (name A→Z, date newest-first, size largest-first; id tiebreak).
    public static func sorted(_ list: [SharedFile], by order: SharedFilesSort) -> [SharedFile] {
        list.sorted { a, b in
            switch order {
            case .name:
                let c = a.name.localizedCaseInsensitiveCompare(b.name)
                if c != .orderedSame { return c == .orderedAscending }
            case .date:
                switch (dateValue(a), dateValue(b)) {
                case let (da?, db?):
                    if da != db { return da > db }
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): break
                }
            case .size:
                if a.size != b.size { return a.size > b.size }
            }
            return a.id < b.id
        }
    }

    /// Pure type-filter (`.all` passes everything through untouched).
    public static func filtered(_ list: [SharedFile], by filter: SharedFilesTypeFilter) -> [SharedFile] {
        filter == .all ? list : list.filter { filter.matches($0) }
    }

    /// Pure filter-then-sort (backs `displayedFiles`).
    public static func displayed(
        _ list: [SharedFile], sort: SharedFilesSort, filter: SharedFilesTypeFilter
    ) -> [SharedFile] {
        Self.sorted(Self.filtered(list, by: filter), by: sort)
    }

    static func message(for error: Error) -> String {
        if case CoreCallError.failed(let m) = error { return m }
        return String(describing: error)
    }
}

/// Shared-tab file list: rows with Open + Save-as, multi-upload, sort +
/// type-filter controls, Refresh toolbar.
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
    /// Drop highlight (om-iu-dropquick): accent outline while a file
    /// drop hovers the tab.
    @State private var dropTargeted = false

    public init(store: SharedFilesStore) {
        self.store = store
    }

    /// Skeleton gate (om-fix-tabs): spinner only when data is truly
    /// absent (loading + no rows). A refresh over cached rows keeps the
    /// list on screen — tab switches never blank. Pure, testable.
    public nonisolated static func showsSkeleton(state: SharedFilesState, filesEmpty: Bool) -> Bool {
        state == .loading && filesEmpty
    }

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            controls
            DietSeamH()
            if !store.isRoot { breadcrumbs }
            if !store.isRoot { DietSeamH() }
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
            VStack(spacing: DietSpace.row) {
                Text("Copy “\(file.name)”").font(DietType.headline)
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
        .onDrop(of: FileDrop.dropTypes, isTargeted: $dropTargeted) { providers in
            guard store.chatID != nil else { return false }
            FileDrop.resolve(providers: providers) { store.upload(paths: $0) }
            return true
        }
        .dropHighlight(active: dropTargeted)
    }

    private func renameSheet(_ file: SharedFile) -> some View {
        VStack(spacing: DietSpace.row) {
            Text("Rename “\(file.name)”").font(DietType.headline)
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
        VStack(spacing: DietSpace.row) {
            Text(title).font(DietType.headline)
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
        HStack(spacing: DietSpace.xs) {
            Button("‹ Back") { store.back() }
                .font(DietType.caption1)
                .buttonStyle(.link)
            Text("·").foregroundStyle(DietColor.textSecondaryColor)
            Button("Files") { store.goToRoot() }
                .font(DietType.caption1)
                .buttonStyle(.link)
            ForEach(Array(store.crumbs.enumerated()), id: \.offset) { i, crumb in
                Text("/").foregroundStyle(DietColor.textSecondaryColor).font(DietType.caption1)
                if i == store.crumbs.count - 1 {
                    Text(crumb.name)
                        .font(DietType.caption1)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                } else {
                    Button(crumb.name) { store.goTo(depth: i + 1) }
                        .font(DietType.caption1)
                        .buttonStyle(.link)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, DietSpace.xs)
    }

    private var toolbar: some View {
        VStack(spacing: DietSpace.xs) {
            HStack {
                Text("\(store.displayedFiles.count) files")
                    .font(DietType.caption1).monospaced()
                    .foregroundStyle(DietColor.textSecondaryColor)
                if let saved = store.savedPath {
                    Text("saved \(saved)")
                        .font(DietType.caption1)
                        .foregroundStyle(Color(nsColor: DietColor.success))
                        .lineLimit(1)
                        .textSelection(.enabled)
                    if QuickLookPreview.canPreview(path: saved) {
                        Button("Preview") {
                            QuickLookPreview.shared.preview(paths: [saved])
                        }
                        .font(DietType.caption1)
                        .help("Preview the saved file (Quick Look)")
                    }
                }
                Spacer()
                if store.uploading {
                    if let frac = store.uploadProgress {
                        Text("\(Int((frac * 100).rounded()))%")
                            .font(DietType.caption1).monospaced()
                            .foregroundStyle(DietColor.textSecondaryColor)
                    }
                    ProgressView().controlSize(.small)
                }
                Button("Upload…") { pickAndUpload() }
                    .font(DietType.caption1)
                    .disabled(store.uploading || store.chatID == nil)
                    .help("Upload files (<4 MB each) to this chat")
                Button("Refresh") { store.refresh() }
                    .font(DietType.caption1)
                    .disabled(store.chatID == nil)
            }
            if let err = store.uploadError {
                HStack {
                    Text(err)
                        .font(DietType.caption1)
                        .foregroundStyle(Color(nsColor: DietColor.danger))
                        .lineLimit(1)
                    Spacer()
                    Button("Dismiss") { store.clearUploadError() }
                        .font(DietType.caption1)
                        .buttonStyle(.link)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, DietSpace.sm)
    }

    private var controls: some View {
        HStack(spacing: DietSpace.sm) {
            Picker("Sort", selection: $store.sort) {
                ForEach(SharedFilesSort.allCases, id: \.self) { order in
                    Text(order.label).tag(order)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 210)
            .help("Sort shared files")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DietSpace.sm) {
                    ForEach(SharedFilesTypeFilter.allCases, id: \.self) { kind in
                        Button(kind.label) { store.filter = kind }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .opacity(store.filter == kind ? 1 : 0.55)
                            .help("Show \(kind.label.lowercased()) files")
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.bottom, DietSpace.sm)
    }

    @ViewBuilder
    private var content: some View {
        if Self.showsSkeleton(state: store.state, filesEmpty: store.files.isEmpty) {
            VStack {
                Spacer()
                ProgressView("Loading shared files…")
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            loadedContent
        }
    }

    @ViewBuilder
    private var loadedContent: some View {
        switch store.state {
        case .loading, .loaded:
            fileList
        case .empty:
            DietEmptyState(
                systemImage: "folder",
                title: store.isRoot ? "No shared files yet." : "This folder is empty.",
                message: store.isRoot
                    ? "Files shared in this conversation appear here."
                    : "Files in this folder appear here.")
        case let .error(message):
            DietEmptyState(
                systemImage: "exclamationmark.triangle",
                title: "Couldn't load shared files",
                message: message,
                actionLabel: "Retry",
                action: { store.refresh() })
        }
    }

    private var fileList: some View {
        List(store.displayedFiles) { file in
                SharedFileRow(
                    file: file,
                    saving: store.savingIDs.contains(file.id),
                    linking: store.linkingIDs.contains(file.id),
                    linked: store.link(for: file) != nil,
                    managing: store.managingIDs.contains(file.id),
                    onOpen: { store.open(file) },
                    onSave: { saveAsPanel(file) },
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
                    Divider() // native context-menu separator; keep.
                    Button("Delete…", role: .destructive) {
                        deleteTarget = file
                    }
                    // end om-i3-manage region
                }
            }
            .listStyle(.plain)
    }

    private func pickAndUpload() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            store.upload(paths: panel.urls.map(\.path))
        }
    }

    /// Save-as panel defaulting to ~/Downloads/<name>; the picked path goes
    /// to core. No drive_id → quick `save` (browser fallback for the
    /// pre-signed URL, no panel).
    private func saveAsPanel(_ file: SharedFile) {
        guard file.drive_id != nil else {
            store.save(file)
            return
        }
        let panel = NSSavePanel()
        panel.directoryURL = SharedFilesStore.saveAsDirectory()
        panel.nameFieldStringValue = SharedFilesStore.saveAsName(for: file)
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            store.saveAs(file, to: url.path)
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
            Button(action: onDrill) {
                HStack(spacing: DietSpace.sm) {
                    Image(systemName: "folder")
                        .font(DietType.title2)
                        .foregroundStyle(DietColor.textSecondaryColor)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: DietSpace.xxs) {
                        Text(file.name)
                            .font(DietType.body)
                            .lineLimit(1)
                            .textSelection(.enabled)
                        Text("Folder")
                            .font(DietType.caption1)
                            .foregroundStyle(DietColor.textSecondaryColor)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(DietType.caption1)
                        .foregroundStyle(DietColor.textSecondaryColor)
                }
                .padding(.vertical, DietSpace.xs)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open folder \(file.name)")
            .accessibilityHint("Shows this folder's files")
        } else {
            HStack(spacing: DietSpace.sm) {
                Image(systemName: file.isFolder ? "folder" : file.iconName)
                    .font(DietType.title2)
                    .foregroundStyle(DietColor.textSecondaryColor)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: DietSpace.xxs) {
                    Text(file.name)
                        .font(DietType.body)
                        .lineLimit(1)
                        .textSelection(.enabled)
                    HStack(spacing: DietSpace.xs) {
                        Text(file.sizeLabel)
                            .font(DietType.caption1).monospaced()
                            .foregroundStyle(DietColor.textSecondaryColor)
                        if let sender = file.sender {
                            Text("· \(sender)")
                                .font(DietType.caption1)
                                .foregroundStyle(DietColor.textSecondaryColor)
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
                            .font(DietType.caption1)
                            .help("Open in SharePoint (browser)")
                    }
                    if file.drive_id != nil || file.download_url != nil {
                        Button("Save", action: onSave)
                            .buttonStyle(.link)
                            .font(DietType.caption1)
                            .help("Save as… (defaults to ~/Downloads)")
                    }
                    if file.drive_id != nil {
                        SharedFileLinkButton(linking: linking, linked: linked, onTap: onLink)
                    }
                }
            }
            .padding(.vertical, DietSpace.xs)
        }
    }
}
