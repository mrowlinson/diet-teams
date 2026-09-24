// SharedFiles.swift — om-shared lane: Shared tab (chat files via Graph).
//
// Chat files (OneDrive "Microsoft Teams Chat Files" via message attachments)
// and channel files (SharePoint filesFolder) share one list model. Swift
// opens web_url in the browser and saves via core (drive download, Save-as
// panel defaulting to ~/Downloads/<name>); upload posts a reference
// attachment message (<4 MB, pre-gated like the composer).
//
//   let store = SharedFilesStore()
//   store.open(chatID: "19:...")   // list via core (replaces files)
//   store.upload(paths: urls.map(\.path)) // multi-upload, cap-gated
//   store.saveAs(file, to: panel.url!.path)
//   store.displayedFiles           // filter + sort applied
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
    public typealias UploadFetcher = @Sendable (String, String) throws -> SharedFileUploadResponse
    public typealias DownloadFetcher = @Sendable (String, String, String) throws -> SharedFileDownloadResponse
    public typealias OpenURLFn = @Sendable (URL) -> Bool
    /// File-size probe (bytes), nil when unreadable (stages as 0 B).
    /// Same seam as the composer (om-iu-rowdepth pre-gate).
    public typealias SizeProbe = ComposeAttachmentsStore.SizeProbe

    @Published public private(set) var files: [SharedFile] = []
    @Published public private(set) var state: SharedFilesState = .loading
    @Published public private(set) var uploading = false
    @Published public private(set) var savingIDs: Set<String> = []
    @Published public private(set) var savedPath: String?
    /// Paths skipped by the 4 MB pre-gate on the last upload call.
    @Published public private(set) var gatedUploads: [String] = []
    /// Cap message for the last gated upload (composer wording).
    @Published public private(set) var uploadError: String?
    /// Sort + type filter (bound to the toolbar controls).
    @Published public var sort: SharedFilesSort = .date
    @Published public var filter: SharedFilesTypeFilter = .all
    public private(set) var chatID: String?
    public private(set) var isDemo = false

    private let listFetcher: ListFetcher
    private let uploadFetcher: UploadFetcher
    private let downloadFetcher: DownloadFetcher
    private let openURLFn: OpenURLFn
    private let sizeProbe: SizeProbe
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
        openURL: @escaping OpenURLFn = SharedFilesStore.defaultOpenURL,
        sizeProbe: @escaping SizeProbe = ComposeAttachmentsStore.defaultSizeProbe
    ) {
        self.listFetcher = list
        self.uploadFetcher = upload
        self.downloadFetcher = download
        self.openURLFn = openURL
        self.sizeProbe = sizeProbe
    }

    /// Files after the type filter + sort (what the list renders).
    public var displayedFiles: [SharedFile] {
        Self.displayed(files, sort: sort, filter: filter)
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

    /// Upload one local file (single-file convenience over `upload(paths:)`).
    public func upload(path: String) {
        upload(paths: [path])
    }

    /// Multi-upload (om-iu-rowdepth, matches the composer): probe every path,
    /// pre-gate over-cap files into `gatedUploads`/`uploadError` (the fetcher
    /// is never called for them), then upload the rest in pick order,
    /// upserting each result. Failures mark `state` but don't stop later
    /// files. Demo mode fabricates each row locally.
    public func upload(paths: [String]) {
        guard !uploading, let id = chatID, !paths.isEmpty else { return }
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
            state = .loaded
            return
        }
        uploading = true
        Task {
            defer { uploading = false }
            let fetcher = uploadFetcher
            for path in ok {
                do {
                    let resp = try await Task.detached { try fetcher(id, path) }.value
                    files = Self.upsert(resp.file, into: files)
                    state = .loaded
                } catch {
                    state = .error(Self.message(for: error))
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

    /// ~/Downloads/<filename> (pure, testable).
    public static func downloadDestination(filename: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent("Downloads/\(filename)")
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

    public init(store: SharedFilesStore) {
        self.store = store
    }

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            controls
            Divider()
            content
        }
    }

    private var toolbar: some View {
        VStack(spacing: 4) {
            HStack {
                Text("\(store.displayedFiles.count) files")
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
                    .help("Upload files (<4 MB each) to this chat")
                Button("Refresh") { store.refresh() }
                    .font(.caption)
                    .disabled(store.chatID == nil)
            }
            if let err = store.uploadError {
                HStack {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                    Spacer()
                    Button("Dismiss") { store.clearUploadError() }
                        .font(.caption)
                        .buttonStyle(.link)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Picker("Sort", selection: $store.sort) {
                ForEach(SharedFilesSort.allCases, id: \.self) { order in
                    Text(order.label).tag(order)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 210)
            .help("Sort shared files")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
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
        .padding(.bottom, 8)
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
            List(store.displayedFiles) { file in
                SharedFileRow(
                    file: file,
                    saving: store.savingIDs.contains(file.id),
                    onOpen: { store.open(file) },
                    onSave: { saveAsPanel(file) }
                )
            }
            .listStyle(.plain)
        }
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
                        .help("Save as… (defaults to ~/Downloads)")
                }
            }
        }
        .padding(.vertical, 4)
    }
}
