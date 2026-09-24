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
    public typealias RenameFetcher = @Sendable (String, String, String) throws -> SharedFileManageResponse
    public typealias MoveFetcher = @Sendable (String, String, String) throws -> SharedFileManageResponse
    public typealias CopyFetcher = @Sendable (String, String, String, String?) throws -> SharedFileCopyResponse
    public typealias DeleteFetcher = @Sendable (String, String) throws -> SharedFileDeleteResponse
    public typealias OpenURLFn = @Sendable (URL) -> Bool

    @Published public private(set) var files: [SharedFile] = []
    @Published public private(set) var state: SharedFilesState = .loading
    @Published public private(set) var uploading = false
    @Published public private(set) var savingIDs: Set<String> = []
    @Published public private(set) var savedPath: String?
    @Published public private(set) var managingIDs: Set<String> = []
    public private(set) var chatID: String?
    public private(set) var isDemo = false

    private let listFetcher: ListFetcher
    private let uploadFetcher: UploadFetcher
    private let downloadFetcher: DownloadFetcher
    private let renameFetcher: RenameFetcher
    private let moveFetcher: MoveFetcher
    private let copyFetcher: CopyFetcher
    private let deleteFetcher: DeleteFetcher
    private let openURLFn: OpenURLFn
    private var openGeneration = 0

    /// Default URL opener. No-op (returns false) under XCTest so tests never
    /// launch the owner's real browser; NSWorkspace.shared.open in production.
    /// Public: Swift requires default-argument callees of a public init to be public.
    public nonisolated static let defaultOpenURL: OpenURLFn = { url in
        if NSClassFromString("XCTestCase") != nil { return false }
        return NSWorkspace.shared.open(url)
    }

    public nonisolated init(
        list: @escaping ListFetcher = { try RustCore.sharedFiles(chatID: $0, limit: $1) },
        upload: @escaping UploadFetcher = { try RustCore.sharedUpload(chatID: $0, path: $1) },
        download: @escaping DownloadFetcher = {
            try RustCore.sharedDownload(driveID: $0, itemID: $1, dest: $2)
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
        openURL: @escaping OpenURLFn = SharedFilesStore.defaultOpenURL
    ) {
        self.listFetcher = list
        self.uploadFetcher = upload
        self.downloadFetcher = download
        self.renameFetcher = rename
        self.moveFetcher = move
        self.copyFetcher = copy
        self.deleteFetcher = delete
        self.openURLFn = openURL
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
                    managing: store.managingIDs.contains(file.id),
                    onOpen: { store.open(file) },
                    onSave: { store.save(file) }
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
    var managing: Bool = false
    var onOpen: () -> Void = {}
    var onSave: () -> Void = {}

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
            }
        }
        .padding(.vertical, 4)
    }
}
