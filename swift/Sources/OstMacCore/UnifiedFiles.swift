// UnifiedFiles.swift — top10-files lane: ONE Files surface.
//
// MSP consensus: files scatter across per-chat Shared tabs, channel
// folders, and OneDrive — and drive uploads with no conversation
// (Q&A exports) appear nowhere. This surface merges three legs into
// one date-sorted recents view:
//
//   chats    — sharedFiles per recent chat (OneDrive chat-folder leg)
//   channels — sharedFiles per channel (SharePoint filesFolder leg)
//   drive    — driveRecents (/me/drive/recent: OneDrive + SharePoint)
//
// Rows reuse the Shared-tab `SharedFile` shape, sort/filter pures, and
// the Save-first flow (core download → ~/Downloads → QuickLook preview
// + share sheet). Upload targets the first chat spec (panel + drops).
//
//   let store = UnifiedFilesStore()
//   store.load(chats: [(id, name)], channels: [(id, name)])
//   store.displayedRows  // source + type filter + sort applied
//   store.preview(row)   // save-first QuickLook
//   store.share(row)     // save-first NSSharingServicePicker
// Tests inject mock fetchers (same seam as SharedFilesStore).
import AppKit
import DietDesign
import Foundation
import SwiftUI

/// Which leg a unified row came from.
public enum UnifiedFileSource: String, CaseIterable, Sendable {
    case chat
    case channel
    case drive

    public var label: String {
        switch self {
        case .chat: return "Chat"
        case .channel: return "Channel"
        case .drive: return "OneDrive"
        }
    }
}

/// Source filter chips above the recents list.
public enum UnifiedFileSourceFilter: String, CaseIterable, Sendable {
    case all
    case chats
    case channels
    case drive

    public var label: String {
        switch self {
        case .all: return "All"
        case .chats: return "Chats"
        case .channels: return "Channels"
        case .drive: return "OneDrive"
        }
    }

    public func matches(_ row: UnifiedFileRow) -> Bool {
        switch self {
        case .all: return true
        case .chats: return row.source == .chat
        case .channels: return row.source == .channel
        case .drive: return row.source == .drive
        }
    }
}

/// One conversation leg to aggregate (chats + channels; the drive leg
/// needs no spec — it is the signed-in user's recents).
public struct UnifiedSourceSpec: Equatable, Sendable {
    public let kind: UnifiedFileSource
    public let id: String
    public let name: String

    public init(kind: UnifiedFileSource, id: String, name: String) {
        self.kind = kind
        self.id = id
        self.name = name
    }
}

/// One merged row: a Shared-tab file tagged with its leg + origin name
/// ("Design Sync", "Platform > #general", "OneDrive").
public struct UnifiedFileRow: Identifiable, Equatable, Sendable {
    public let file: SharedFile
    public let source: UnifiedFileSource
    public let sourceName: String

    /// Dedupe key (drive-scoped; bare ids are chat-path rows without one).
    public var id: String { Self.key(for: file) }

    public init(file: SharedFile, source: UnifiedFileSource, sourceName: String) {
        self.file = file
        self.source = source
        self.sourceName = sourceName
    }

    public static func key(for file: SharedFile) -> String {
        if let drive = file.drive_id { return "\(drive)\n\(file.id)" }
        return file.id
    }
}

/// Save-first share sheet: NSSharingServicePicker over local files.
/// The anchor is the key window's content view (nil = headless no-op).
public enum ShareSheet {
    @MainActor
    public static func show(items: [Any]) {
        guard !items.isEmpty,
              let anchor = NSApp.keyWindow?.contentView ?? NSApp.mainWindow?.contentView
        else { return }
        NSSharingServicePicker(items: items)
            .show(relativeTo: .zero, of: anchor, preferredEdge: .minY)
    }
}

@MainActor
public final class UnifiedFilesStore: ObservableObject {
    public typealias ListFetcher = SharedFilesStore.ListFetcher
    public typealias RecentsFetcher = @Sendable (Int32) throws -> DriveRecentsResponse
    public typealias UploadFetcher = SharedFilesStore.UploadFetcher
    public typealias DownloadFetcher = SharedFilesStore.DownloadFetcher
    public typealias LinkFetcher = SharedFilesStore.LinkFetcher
    public typealias OpenURLFn = SharedFilesStore.OpenURLFn
    public typealias CopyLinkFn = SharedFilesStore.CopyLinkFn
    public typealias SizeProbe = ComposeAttachmentsStore.SizeProbe
    /// QuickLook entry (save-first: always a local path). Tests inject
    /// a capturing closure; default opens the QL panel (no-op in XCTest).
    public typealias PreviewFn = @Sendable (String) -> Void
    /// Share-sheet entry (save-first: always local file URLs + fallback
    /// web URLs). Same seam as PreviewFn.
    public typealias ShareFn = @Sendable ([Any]) -> Void

    /// Live fan-out caps: the 10 most recent chats + 20 channels keep
    /// the merge to ~31 core calls (each chat leg is 1 + N shares
    /// resolves; channels are 1 + team scan).
    public nonisolated static let maxChats = 10
    public nonisolated static let maxChannels = 20

    @Published public private(set) var rows: [UnifiedFileRow] = []
    @Published public private(set) var state: SharedFilesState = .loading
    @Published public private(set) var uploading = false
    @Published public private(set) var uploadProgress: Double?
    @Published public private(set) var savingIDs: Set<String> = []
    @Published public private(set) var linkingIDs: Set<String> = []
    @Published public private(set) var links: [String: String] = [:]
    /// Saved local copies by row key (Save-first flow: QL + share read here).
    @Published public private(set) var savedPaths: [String: String] = [:]
    @Published public private(set) var gatedUploads: [String] = []
    @Published public private(set) var uploadError: String?
    @Published public var sort: SharedFilesSort = .date
    @Published public var filter: SharedFilesTypeFilter = .all
    @Published public var sourceFilter: UnifiedFileSourceFilter = .all
    public private(set) var specs: [UnifiedSourceSpec] = []
    public private(set) var isDemo = false

    private let listFetcher: ListFetcher
    private let recentsFetcher: RecentsFetcher
    private let uploadFetcher: UploadFetcher
    private let downloadFetcher: DownloadFetcher
    private let linkFetcher: LinkFetcher
    private let openURLFn: OpenURLFn
    private let copyLinkFn: CopyLinkFn
    private let sizeProbe: SizeProbe
    private let previewFn: PreviewFn
    private let shareFn: ShareFn
    private var loadGeneration = 0
    /// Rows awaiting QL/share after their save lands (save-then-act).
    private var pendingPreview: Set<String> = []
    private var pendingShare: Set<String> = []

    /// Default QuickLook entry. No-op under XCTest (never opens the
    /// panel in tests); the Task hop keeps the closure nonisolated-safe.
    public nonisolated static let defaultPreview: PreviewFn = { path in
        if NSClassFromString("XCTestCase") != nil { return }
        Task { @MainActor in QuickLookPreview.shared.preview(paths: [path]) }
    }

    /// Default share-sheet entry. No-op under XCTest (never touches
    /// the service picker in tests).
    public nonisolated static let defaultShare: ShareFn = { items in
        if NSClassFromString("XCTestCase") != nil { return }
        Task { @MainActor in ShareSheet.show(items: items) }
    }

    public nonisolated init(
        list: @escaping ListFetcher = {
            try RustCore.sharedFiles(chatID: $0, limit: $1, includeFolders: true)
        },
        recents: @escaping RecentsFetcher = { try RustCore.driveRecents(limit: $0) },
        upload: @escaping UploadFetcher = { try RustCore.sharedUpload(chatID: $0, path: $1) },
        download: @escaping DownloadFetcher = {
            try RustCore.sharedDownload(driveID: $0, itemID: $1, dest: $2)
        },
        link: @escaping LinkFetcher = {
            try RustCore.sharedLink(driveID: $0, itemID: $1, scope: $2)
        },
        openURL: @escaping OpenURLFn = SharedFilesStore.defaultOpenURL,
        copyLink: @escaping CopyLinkFn = SharedFilesStore.defaultCopyLink,
        sizeProbe: @escaping SizeProbe = ComposeAttachmentsStore.defaultSizeProbe,
        preview: @escaping PreviewFn = UnifiedFilesStore.defaultPreview,
        share: @escaping ShareFn = UnifiedFilesStore.defaultShare
    ) {
        self.listFetcher = list
        self.recentsFetcher = recents
        self.uploadFetcher = upload
        self.downloadFetcher = download
        self.linkFetcher = link
        self.openURLFn = openURL
        self.copyLinkFn = copyLink
        self.sizeProbe = sizeProbe
        self.previewFn = preview
        self.shareFn = share
    }

    // MARK: - Pure merge/specs/display

    /// Live specs from the loaded lists: the `maxChats` most recent
    /// chats (list order is recency) + flattened team channels capped at
    /// `maxChannels`. Channel rows read "Team > #channel".
    public static func specsFor(
        chats: [ChatItem], teams: [TeamItem],
        chatCap: Int = maxChats, channelCap: Int = maxChannels
    ) -> [UnifiedSourceSpec] {
        var out: [UnifiedSourceSpec] = chats.prefix(max(0, chatCap)).map {
            UnifiedSourceSpec(kind: .chat, id: $0.chatId, name: $0.name)
        }
        var channels = 0
        for team in teams {
            for channel in team.channels {
                guard channels < max(0, channelCap) else { break }
                out.append(UnifiedSourceSpec(
                    kind: .channel, id: channel.channelId,
                    name: "\(team.name) > #\(channel.name)"))
                channels += 1
            }
            if channels >= max(0, channelCap) { break }
        }
        return out
    }

    /// Pure merge: tag every leg file with its source, dedupe by row key
    /// (conversation legs win over the drive leg: pass drive files last).
    /// Order preserved (first-wins); callers sort via `displayed`.
    public static func merge(
        legs: [(source: UnifiedFileSource, sourceName: String, files: [SharedFile])]
    ) -> [UnifiedFileRow] {
        var seen = Set<String>()
        var out: [UnifiedFileRow] = []
        for leg in legs {
            for file in leg.files {
                let key = UnifiedFileRow.key(for: file)
                guard seen.insert(key).inserted else { continue }
                out.append(UnifiedFileRow(
                    file: file, source: leg.source, sourceName: leg.sourceName))
            }
        }
        return out
    }

    /// Pure source-filter (`.all` passes everything through untouched).
    public static func sourceFiltered(
        _ list: [UnifiedFileRow], by filter: UnifiedFileSourceFilter
    ) -> [UnifiedFileRow] {
        filter == .all ? list : list.filter { filter.matches($0) }
    }

    /// Pure filter-then-sort (backs `displayedRows`). Reuses the
    /// Shared-tab type filter + sort on the wrapped files; the row
    /// order follows the sorted files (keys are unique post-merge).
    public static func displayed(
        _ list: [UnifiedFileRow], sort: SharedFilesSort,
        filter: SharedFilesTypeFilter, sourceFilter: UnifiedFileSourceFilter
    ) -> [UnifiedFileRow] {
        let scoped = sourceFiltered(list, by: sourceFilter)
        let files = SharedFilesStore.displayed(
            scoped.map(\.file), sort: sort, filter: filter)
        let byKey = Dictionary(uniqueKeysWithValues: scoped.map { ($0.id, $0) })
        return files.compactMap { byKey[UnifiedFileRow.key(for: $0)] }
    }

    /// "2026-09-25T10:00:00Z" → "Sep 25, 2026" (nil when dateless).
    public static func dateLabel(_ file: SharedFile) -> String? {
        guard let date = SharedFilesStore.dateValue(file) else { return nil }
        return Self.shortDate.string(from: date)
    }

    private static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    /// Share payload for one row: the saved local file URL when a copy
    /// exists (service picker uploads/shares bytes), else the SharePoint
    /// web URL (link share). Nil when neither exists.
    public static func shareItems(for row: UnifiedFileRow, savedPath: String?) -> [Any] {
        if let path = savedPath, QuickLookPreview.canPreview(path: path) {
            return [URL(fileURLWithPath: path)]
        }
        if let s = row.file.web_url, let url = URL(string: s) {
            return [url]
        }
        return []
    }

    /// Demo placeholder content for a fabricated save (offline: real
    /// bytes so QuickLook + share work in demo with zero network).
    public static func demoFileContent(for file: SharedFile) -> String {
        "\(file.name)\nDemo copy — \(file.sizeLabel) in the shared library.\n"
    }

    /// Demo save destination: a tmp subdir, never ~/Downloads (demo
    /// fabrications must not litter the owner's real folders). Pure.
    public static func demoSaveDestination(filename: String) -> String {
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("UnifiedFilesDemo")
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        return (dir as NSString).appendingPathComponent(filename)
    }

    /// Core-call failure message (nonisolated: TaskGroup legs call it
    /// off the main actor). Same shape as SharedFilesStore.message.
    nonisolated static func message(for error: Error) -> String {
        if case CoreCallError.failed(let m) = error { return m }
        return String(describing: error)
    }

    // MARK: - Load

    /// Rows after the source + type filters + sort (what the list renders).
    public var displayedRows: [UnifiedFileRow] {
        Self.displayed(rows, sort: sort, filter: filter, sourceFilter: sourceFilter)
    }

    /// Upload target: the first chat leg, else the first channel leg
    /// (drive recents are read-only — nowhere to post a reference).
    /// Nil with no conversation legs (upload disabled).
    public var uploadTarget: UnifiedSourceSpec? {
        specs.first { $0.kind == .chat } ?? specs.first { $0.kind == .channel }
    }

    /// Existing saved copy for one row (Save-first flow reads here).
    /// Drops stale entries (user deleted the file behind us).
    public func localPath(for row: UnifiedFileRow) -> String? {
        guard let path = savedPaths[row.id],
              QuickLookPreview.canPreview(path: path)
        else { return nil }
        return path
    }

    /// Load the merged view: every spec's shared list + drive recents,
    /// fanned out concurrently. Partial legs still merge (one chat's
    /// 404 never blanks the surface); all-legs-failed surfaces the
    /// first error. Stale completions are dropped (fast refresh lands
    /// newest). Demo mode stays offline (see `showDemo`).
    public func load(
        chats: [(id: String, name: String)],
        channels: [(id: String, name: String)],
        limitPerSource: Int32 = 10, recentsLimit: Int32 = 25
    ) {
        let next = chats.map {
            UnifiedSourceSpec(kind: .chat, id: $0.id, name: $0.name)
        } + channels.map {
            UnifiedSourceSpec(kind: .channel, id: $0.id, name: $0.name)
        }
        specs = next
        isDemo = false
        loadGeneration += 1
        let gen = loadGeneration
        state = .loading
        let list = listFetcher
        let recents = recentsFetcher
        Task {
            var legs: [(source: UnifiedFileSource, sourceName: String, files: [SharedFile])] =
                Array(repeating: (source: .chat, sourceName: "", files: []), count: next.count + 1)
            var landed = 0
            var firstError: String?
            await withTaskGroup(of: (Int, [SharedFile]?, String?).self) { group in
                for (i, spec) in next.enumerated() {
                    group.addTask {
                        do {
                            let resp = try await Task.detached {
                                try list(spec.id, limitPerSource)
                            }.value
                            return (i, resp.files, nil)
                        } catch {
                            return (i, nil, Self.message(for: error))
                        }
                    }
                }
                group.addTask {
                    do {
                        let resp = try await Task.detached {
                            try recents(recentsLimit)
                        }.value
                        return (next.count, resp.files, nil)
                    } catch {
                        return (next.count, nil, Self.message(for: error))
                    }
                }
                for await (i, files, err) in group {
                    if let files {
                        landed += 1
                        if i < next.count {
                            legs[i] = (next[i].kind, next[i].name, files)
                        } else {
                            legs[i] = (.drive, UnifiedFileSource.drive.label, files)
                        }
                    } else if firstError == nil {
                        firstError = err
                    }
                }
            }
            guard gen == loadGeneration else { return }
            let merged = Self.merge(legs: legs.filter {
                !($0.sourceName.isEmpty && $0.files.isEmpty)
            })
            rows = merged
            if !merged.isEmpty {
                state = .loaded
            } else if landed == 0, let err = firstError {
                state = .error(err)
            } else {
                state = .empty
            }
        }
    }

    /// Demo mode: canned rows offline (no core). Resets specs to the
    /// demo conversations.
    public func showDemo(specs: [UnifiedSourceSpec], rows: [UnifiedFileRow]) {
        self.specs = specs
        self.rows = rows
        isDemo = true
        state = rows.isEmpty ? .empty : .loaded
    }

    /// Fire-and-forget reload with the current specs.
    public func refresh(limitPerSource: Int32 = 10, recentsLimit: Int32 = 25) {
        guard !isDemo else { return }
        load(
            chats: specs.filter { $0.kind == .chat }.map { ($0.id, $0.name) },
            channels: specs.filter { $0.kind == .channel }.map { ($0.id, $0.name) },
            limitPerSource: limitPerSource, recentsLimit: recentsLimit)
    }

    // MARK: - Row actions (Save-first: download → preview/share)

    /// Open the SharePoint page in the browser. No-op without a web_url.
    /// Returns the URL opened, if any (test seam).
    @discardableResult
    public func open(_ row: UnifiedFileRow) -> URL? {
        guard let s = row.file.web_url, let url = URL(string: s) else { return nil }
        _ = openURLFn(url)
        return url
    }

    /// Quick save to ~/Downloads/<name>, then run `after` (preview/share
    /// continuations). The view prefers `saveAs` (Save panel defaulting
    /// there). Demo mode fabricates a placeholder file offline.
    public func save(_ row: UnifiedFileRow, after: ((UnifiedFileRow) -> Void)? = nil) {
        saveAs(row, to: SharedFilesStore.downloadDestination(filename: row.file.name), after: after)
    }

    /// Save to an explicit destination (the Save panel's pick). Needs
    /// drive_id; without it falls back to opening the pre-signed
    /// download_url in the browser (dest unused, no continuation).
    public func saveAs(
        _ row: UnifiedFileRow, to dest: String,
        after: ((UnifiedFileRow) -> Void)? = nil
    ) {
        if isDemo {
            // Fabricated bytes land in tmp (never ~/Downloads); the
            // passed dest is ignored so demo previews stay hermetic.
            let demoDest = Self.demoSaveDestination(filename: row.file.name)
            let content = Self.demoFileContent(for: row.file)
            try? content.write(toFile: demoDest, atomically: true, encoding: .utf8)
            if QuickLookPreview.canPreview(path: demoDest) {
                savedPaths[row.id] = demoDest
            }
            after?(row)
            return
        }
        guard let drive = row.file.drive_id else {
            if let s = row.file.download_url, let url = URL(string: s) {
                _ = openURLFn(url)
            }
            return
        }
        guard !savingIDs.contains(row.id) else { return }
        savingIDs.insert(row.id)
        let fetcher = downloadFetcher
        let file = row.file
        Task {
            defer { savingIDs.remove(row.id) }
            do {
                let resp = try await Task.detached {
                    try fetcher(drive, file.id, dest)
                }.value
                savedPaths[row.id] = resp.path
                after?(row)
            } catch {
                state = .error(Self.message(for: error))
            }
        }
    }

    /// QuickLook preview, save-first: an existing local copy opens at
    /// once; otherwise the row saves to ~/Downloads and the panel opens
    /// when the bytes land. Remote-only rows (no drive_id) open in the
    /// browser instead (no bytes, no panel).
    public func preview(_ row: UnifiedFileRow) {
        if let local = localPath(for: row) {
            previewFn(local)
            return
        }
        guard row.file.drive_id != nil || isDemo else {
            save(row) // browser fallback for the pre-signed URL
            return
        }
        pendingPreview.insert(row.id)
        save(row) { [weak self] done in
            guard let self, pendingPreview.remove(done.id) != nil else { return }
            if let local = localPath(for: done) { previewFn(local) }
        }
    }

    /// Share sheet, save-first: an existing local copy shares bytes
    /// (upload-capable services); otherwise the row saves first and the
    /// picker opens when the bytes land. With no local copy and no
    /// web_url there is nothing to share (guarded no-op).
    public func share(_ row: UnifiedFileRow) {
        let items = Self.shareItems(for: row, savedPath: localPath(for: row))
        if !items.isEmpty, localPath(for: row) != nil || row.file.drive_id == nil {
            shareFn(items)
            return
        }
        guard row.file.drive_id != nil || isDemo else { return }
        pendingShare.insert(row.id)
        save(row) { [weak self] done in
            guard let self, pendingShare.remove(done.id) != nil else { return }
            let items = Self.shareItems(for: done, savedPath: localPath(for: done))
            if !items.isEmpty { shareFn(items) }
        }
    }

    /// Cached sharing link for one row (createLink result, or the row's
    /// own share_url when core filled it). Nil until linked.
    public func link(for row: UnifiedFileRow) -> String? {
        links[row.id] ?? row.file.share_url
    }

    /// Create a view-only sharing link via core and copy it to the
    /// pasteboard. Cached links re-copy without refetching. No-op
    /// without a drive_id; demo mode fabricates a stable link.
    public func shareLink(_ row: UnifiedFileRow, scope: String = "organization") {
        if let cached = link(for: row) {
            copyLinkFn(cached)
            return
        }
        guard let drive = row.file.drive_id else { return }
        if isDemo {
            let demo = SharedFileLink.demoLink(for: row.file.id)
            links[row.id] = demo
            copyLinkFn(demo)
            return
        }
        guard !linkingIDs.contains(row.id) else { return }
        linkingIDs.insert(row.id)
        let fetcher = linkFetcher
        let file = row.file
        Task {
            defer { linkingIDs.remove(row.id) }
            do {
                let resp = try await Task.detached {
                    try fetcher(drive, file.id, scope)
                }.value
                links[row.id] = resp.link
                copyLinkFn(resp.link)
            } catch {
                state = .error(Self.message(for: error))
            }
        }
    }

    // MARK: - Upload (targets the first conversation leg)

    /// Multi-upload to the upload target (panel + drops): over-cap
    /// files pre-gate into `gatedUploads`/`uploadError` (the fetcher
    /// never runs for them); the rest upload one at a time and upsert
    /// into the merged rows tagged with the target leg. No-op without
    /// a target. Demo mode fabricates each row locally.
    public func upload(paths: [String]) {
        guard !paths.isEmpty, let target = uploadTarget else { return }
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
                rows.insert(
                    UnifiedFileRow(
                        file: SharedFile(id: "demo-up-\(rows.count + 1)", name: name, size: 1024),
                        source: target.kind, sourceName: target.name),
                    at: 0)
            }
            state = .loaded
            return
        }
        uploading = true
        uploadProgress = nil
        let fetcher = uploadFetcher
        Task {
            defer {
                uploading = false
                uploadProgress = nil
            }
            for path in ok {
                do {
                    let resp = try await Task.detached {
                        try fetcher(target.id, path)
                    }.value
                    rows = Self.upsert(
                        UnifiedFileRow(
                            file: resp.file, source: target.kind,
                            sourceName: target.name),
                        into: rows)
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

    /// Pure upsert: same key replaces in place, new key prepends.
    public static func upsert(_ row: UnifiedFileRow, into list: [UnifiedFileRow]) -> [UnifiedFileRow] {
        var out = list
        if let i = out.firstIndex(where: { $0.id == row.id }) {
            out[i] = row
        } else {
            out.insert(row, at: 0)
        }
        return out
    }
}

// MARK: - View

/// Unified Files surface: one recents list across chats, channels, and
/// OneDrive, with source badges, sort + filters, Save-first QuickLook
/// preview + share sheet, and upload to the first conversation leg.
public struct UnifiedFilesView: View {
    @ObservedObject public var store: UnifiedFilesStore
    /// Drop highlight: accent outline while a file drop hovers the view.
    @State private var dropTargeted = false

    public init(store: UnifiedFilesStore) {
        self.store = store
    }

    /// Skeleton gate: spinner only when data is truly absent (loading +
    /// no rows). A refresh over cached rows keeps the list on screen.
    /// Pure, testable.
    public nonisolated static func showsSkeleton(state: SharedFilesState, rowsEmpty: Bool) -> Bool {
        state == .loading && rowsEmpty
    }

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            controls
            DietSeamH()
            content
        }
        .onDrop(of: FileDrop.dropTypes, isTargeted: $dropTargeted) { providers in
            guard store.uploadTarget != nil else { return false }
            FileDrop.resolve(providers: providers) { store.upload(paths: $0) }
            return true
        }
        .dropHighlight(active: dropTargeted)
    }

    private var toolbar: some View {
        VStack(spacing: DietSpace.xs) {
            HStack {
                Text("\(store.displayedRows.count) files")
                    .font(DietType.caption1).monospaced()
                    .foregroundStyle(DietColor.textSecondaryColor)
                if let target = store.uploadTarget {
                    Text("→ \(target.name)")
                        .font(DietType.caption1)
                        .foregroundStyle(DietColor.textSecondaryColor)
                        .lineLimit(1)
                        .help("Uploads land in \(target.name)")
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
                    .disabled(store.uploading || store.uploadTarget == nil)
                    .help("Upload files (<4 MB each) to \(store.uploadTarget?.name ?? "—")")
                Button("Refresh") { store.refresh() }
                    .font(DietType.caption1)
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
        VStack(spacing: DietSpace.xs) {
            HStack(spacing: DietSpace.sm) {
                Picker("Sort", selection: $store.sort) {
                    ForEach(SharedFilesSort.allCases, id: \.self) { order in
                        Text(order.label).tag(order)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 210)
                .help("Sort unified files")
                ScrollView(.horizontal) {
                    HStack(spacing: DietSpace.sm) {
                        ForEach(UnifiedFileSourceFilter.allCases, id: \.self) { scope in
                            Button(scope.label) { store.sourceFilter = scope }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .opacity(store.sourceFilter == scope ? 1 : 0.55)
                                .help("Show \(scope.label.lowercased()) files")
                        }
                    }
                }
                .scrollIndicators(.hidden)
                Spacer()
            }
            HStack(spacing: DietSpace.sm) {
                ScrollView(.horizontal) {
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
                .scrollIndicators(.hidden)
                Spacer()
            }
        }
        .padding(.horizontal)
        .padding(.bottom, DietSpace.sm)
    }

    @ViewBuilder
    private var content: some View {
        if Self.showsSkeleton(state: store.state, rowsEmpty: store.rows.isEmpty) {
            VStack {
                Spacer()
                ProgressView("Loading files…")
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
                title: "No files yet.",
                message: "Files shared in chats, channels, and OneDrive appear here.")
        case let .error(message):
            DietEmptyState(
                systemImage: "exclamationmark.triangle",
                title: "Couldn't load files",
                message: message,
                actionLabel: "Retry",
                action: { store.refresh() })
        }
    }

    private var fileList: some View {
        List(store.displayedRows) { row in
            UnifiedFileRowView(
                row: row,
                dateText: UnifiedFilesStore.dateLabel(row.file),
                saving: store.savingIDs.contains(row.id),
                linking: store.linkingIDs.contains(row.id),
                linked: store.link(for: row) != nil,
                saved: store.localPath(for: row) != nil,
                onOpen: { store.open(row) },
                onSave: { saveAsPanel(row) },
                onPreview: { store.preview(row) },
                onShare: { store.share(row) },
                onLink: { store.shareLink(row) }
            )
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

    /// Save-as panel defaulting to ~/Downloads/<name>; the picked path
    /// goes to core. No drive_id → quick `save` (browser fallback for
    /// the pre-signed URL, no panel).
    private func saveAsPanel(_ row: UnifiedFileRow) {
        guard row.file.drive_id != nil || store.isDemo else {
            store.save(row)
            return
        }
        let panel = NSSavePanel()
        panel.directoryURL = SharedFilesStore.saveAsDirectory()
        panel.nameFieldStringValue = SharedFilesStore.saveAsName(for: row.file)
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            store.saveAs(row, to: url.path)
        }
    }
}

/// One unified row: icon + name + source badge, size · source ·
/// sender · date. Preview + Save stay inline (Save-first); Share…,
/// Open, and Copy link live in the context menu — the sidebar browser
/// (~390pt) cannot fit five inline buttons beside the meta line.
struct UnifiedFileRowView: View {
    let row: UnifiedFileRow
    var dateText: String? = nil
    var saving: Bool = false
    var linking: Bool = false
    var linked: Bool = false
    var saved: Bool = false
    var onOpen: () -> Void = {}
    var onSave: () -> Void = {}
    var onPreview: () -> Void = {}
    var onShare: () -> Void = {}
    var onLink: () -> Void = {}

    var body: some View {
        HStack(spacing: DietSpace.sm) {
            Image(systemName: row.file.isFolder ? "folder" : row.file.iconName)
                .font(DietType.title2)
                .foregroundStyle(DietColor.textSecondaryColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: DietSpace.xxs) {
                HStack(spacing: DietSpace.xs) {
                    Text(row.file.name)
                        .font(DietType.body)
                        .lineLimit(1)
                        .textSelection(.enabled)
                    Text(row.source.label)
                        .font(DietType.caption2)
                        .foregroundStyle(DietColor.textSecondaryColor)
                        .padding(.horizontal, DietSpace.xs)
                        .background(DietColor.wellColor)
                        .clipShape(Capsule())
                        .help(row.sourceName)
                }
                HStack(spacing: DietSpace.xs) {
                    Text(row.file.sizeLabel)
                        .font(DietType.caption1).monospaced()
                        .foregroundStyle(DietColor.textSecondaryColor)
                    Text(row.sourceName)
                        .font(DietType.caption1)
                        .foregroundStyle(DietColor.textSecondaryColor)
                        .lineLimit(1)
                    if let sender = row.file.sender {
                        Text("· \(sender)")
                            .font(DietType.caption1)
                            .foregroundStyle(DietColor.textSecondaryColor)
                            .lineLimit(1)
                    }
                    if let date = dateText {
                        Text("· \(date)")
                            .font(DietType.caption1)
                            .foregroundStyle(DietColor.textSecondaryColor)
                    }
                    if saved {
                        Text("· saved")
                            .font(DietType.caption1)
                            .foregroundStyle(Color(nsColor: DietColor.success))
                    }
                }
            }
            Spacer()
            if saving {
                ProgressView().controlSize(.small)
            } else {
                Button("Preview", action: onPreview)
                    .buttonStyle(.link)
                    .font(DietType.caption1)
                    .help("Save to ~/Downloads and preview (Quick Look)")
                if row.file.drive_id != nil || row.file.download_url != nil {
                    Button("Save", action: onSave)
                        .buttonStyle(.link)
                        .font(DietType.caption1)
                        .help("Save as… (defaults to ~/Downloads)")
                }
            }
        }
        .padding(.vertical, DietSpace.xs)
        .contextMenu {
            Button("Share…", action: onShare)
            if row.file.web_url != nil {
                Button("Open in SharePoint", action: onOpen)
            }
            if row.file.drive_id != nil {
                Button(linked ? "Copy Link Again" : "Copy Link", action: onLink)
                    .disabled(linking)
            }
        }
    }
}
