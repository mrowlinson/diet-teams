// SharedFiles.swift — om-shared lane: Shared tab (chat files via Graph).
//
// Chat files (OneDrive "Microsoft Teams Chat Files" via message attachments)
// and channel files (SharePoint filesFolder) share one list model. Swift
// opens web_url in the browser and saves via core (drive download to
// ~/Downloads); upload posts a reference attachment message (<4 MB).
//
//   let store = SharedFilesStore()
//   store.open(chatID: "19:...")   // list via core (replaces files)
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

@MainActor
public final class SharedFilesStore: ObservableObject {
    public typealias ListFetcher = @Sendable (String, Int32) throws -> SharedFilesResponse
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
    public private(set) var chatID: String?
    public private(set) var isDemo = false

    private let listFetcher: ListFetcher
    private let uploadFetcher: UploadFetcher
    private let downloadFetcher: DownloadFetcher
    private let linkFetcher: LinkFetcher
    private let openURLFn: OpenURLFn
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
        list: @escaping ListFetcher = { try RustCore.sharedFiles(chatID: $0, limit: $1) },
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
        self.uploadFetcher = upload
        self.downloadFetcher = download
        self.linkFetcher = link
        self.openURLFn = openURL
        self.copyLinkFn = copyLink
    }

    /// Open a chat/channel: fetch the shared list via core, replace files.
    /// Stale completions are dropped (fast chat-switching lands newest).
    public func open(chatID: String, limit: Int32 = 20) {
        self.chatID = chatID
        state = .loading
        savedPath = nil
        openGeneration += 1
        let gen = openGeneration
        Task {
            let fetcher = listFetcher
            do {
                let resp = try await Task.detached { try fetcher(chatID, limit) }.value
                guard gen == openGeneration else { return }
                files = resp.files
                state = resp.files.isEmpty ? .empty : .loaded
            } catch {
                guard gen == openGeneration else { return }
                state = .error(Self.message(for: error))
            }
        }
    }

    /// Fire-and-forget reload.
    public func refresh(limit: Int32 = 20) {
        guard let id = chatID else { return }
        open(chatID: id, limit: limit)
    }

    /// Demo mode: canned files offline (no core).
    public func showDemo(chatID: String, files: [SharedFile]) {
        self.chatID = chatID
        self.files = files
        isDemo = true
        state = files.isEmpty ? .empty : .loaded
    }

    /// Upload a local file (<4 MB core limit) and prepend the result.
    /// Demo mode fabricates the row locally.
    public func upload(path: String) {
        guard !uploading, let id = chatID else { return }
        if isDemo {
            let name = (path as NSString).lastPathComponent
            files.insert(SharedFile(id: "demo-up-\(files.count + 1)", name: name, size: 1024), at: 0)
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
            content
        }
    }

    private var toolbar: some View {
        HStack {
            Text("\(store.files.count) files")
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
                Text("No shared files yet.")
                    .font(.headline)
                Text("Files shared in this conversation appear here.")
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
    var onLink: () -> Void = {}

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: file.iconName)
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
