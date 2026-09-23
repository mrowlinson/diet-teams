// ComposeAttachments.swift — om-attach lane: composer attachments.
//
// Attach button (native NSOpenPanel) + send-with-upload through the existing
// files-upload path (RustCore.sharedUpload → ostmac_files_upload). Chat ids
// skip the team scan in core (files.rs upload_file_data routes on
// is_channel_id: channels resolve the team folder, chats go straight to the
// sender's OneDrive chat-files folder). The 4 MB simple-upload ceiling is
// gated BEFORE any upload call: over-cap files stage as .tooLarge and never
// reach the fetcher.
//
//   let a = ComposeAttachmentsStore()
//   a.stage(urls: panel.urls)          // probe sizes, gate the cap
//   await a.uploadPending(chatID: id)  // staged only, in order
//
// Tests inject mock upload/size seams (same pattern as SharedFilesStore).
import AppKit
import Foundation
import SwiftUI

/// Per-file composer state (pure, Equatable for tests).
public enum ComposeAttachmentState: Equatable, Sendable {
    /// Under the cap, ready to upload on Send.
    case staged
    /// Over the cap: surfaced in the composer, never uploaded.
    case tooLarge(actual: UInt64)
    /// Upload in flight (row shows a spinner; Send is disabled).
    case uploading
    /// Uploaded via the files-upload path (reference message posted).
    case uploaded
    /// Upload failed (core/network error); Retry re-arms to .staged.
    case failed(String)
}

/// One picked file in the composer.
public struct ComposeAttachment: Identifiable, Equatable, Sendable {
    public let id: String
    public let path: String
    public let name: String
    public let size: UInt64
    public var state: ComposeAttachmentState

    public init(
        id: String = UUID().uuidString,
        path: String, name: String, size: UInt64,
        state: ComposeAttachmentState = .staged
    ) {
        self.id = id
        self.path = path
        self.name = name
        self.size = size
        self.state = state
    }
}

/// Pure composer-attachment helpers (cap gate + picker model).
public enum ComposeAttachments {
    /// Simple-upload ceiling, mirrors Rust MAX_SIMPLE_UPLOAD (files.rs).
    /// Core rejects larger files; the composer gates them first (no call).
    public static let maxUploadBytes: UInt64 = 4 * 1024 * 1024

    /// True when `size` exceeds the ceiling (exactly 4 MB still uploads:
    /// core rejects `len > MAX_SIMPLE_UPLOAD`).
    public static func isTooLarge(size: UInt64) -> Bool {
        size > maxUploadBytes
    }

    /// Cap message surfaced in the composer before upload.
    /// `"File is 5.0 MB; uploads are limited to 4.0 MB"`.
    public static func capMessage(actual: UInt64) -> String {
        "File is \(SharedFile.sizeLabel(actual)); uploads are limited to \(SharedFile.sizeLabel(maxUploadBytes))"
    }

    /// Last path component (`/tmp/a b.pdf` → `a b.pdf`).
    public static func displayName(path: String) -> String {
        (path as NSString).lastPathComponent
    }

    /// Pure picker model: one path + probed size → a staged (or cap-gated)
    /// attachment. The store's `stage` maps panel URLs through this.
    public static func staged(path: String, size: UInt64) -> ComposeAttachment {
        ComposeAttachment(
            path: path, name: displayName(path: path), size: size,
            state: isTooLarge(size: size) ? .tooLarge(actual: size) : .staged)
    }
}

@MainActor
public final class ComposeAttachmentsStore: ObservableObject {
    /// Same shape as the Shared tab uploader: (chatID, path) → uploaded file.
    public typealias UploadFetcher = SharedFilesStore.UploadFetcher
    /// File-size probe (bytes), nil when the file is unreadable (stages as 0 B).
    public typealias SizeProbe = @Sendable (String) -> UInt64?

    @Published public private(set) var attachments: [ComposeAttachment] = []
    /// True while `uploadPending` runs (composer shows progress, Send locks).
    @Published public private(set) var uploading = false
    /// Last upload failure (composer banner). Cap gates stay per-row.
    @Published public private(set) var error: String?

    private let uploadFetcher: UploadFetcher
    private let sizeProbe: SizeProbe

    /// Default size probe (FileManager; test seam overrides it).
    /// Public: Swift requires default-argument callees of a public init to be public.
    public nonisolated static let defaultSizeProbe: SizeProbe = { path in
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?
            .uint64Value
    }

    public nonisolated init(
        upload: @escaping UploadFetcher = { try RustCore.sharedUpload(chatID: $0, path: $1) },
        sizeProbe: @escaping SizeProbe = ComposeAttachmentsStore.defaultSizeProbe
    ) {
        self.uploadFetcher = upload
        self.sizeProbe = sizeProbe
    }

    /// Stage native-picker URLs: probe sizes now, gate the cap immediately.
    /// Over-cap files stage as .tooLarge (surfaced, never uploaded).
    public func stage(urls: [URL]) {
        stage(paths: urls.map(\.path))
    }

    /// Stage local paths (panel output or tests with an injected probe).
    public func stage(paths: [String]) {
        for path in paths {
            let size = sizeProbe(path) ?? 0
            attachments.append(ComposeAttachments.staged(path: path, size: size))
        }
    }

    /// Remove one row (any state except in-flight .uploading).
    public func remove(id: String) {
        attachments.removeAll { $0.id == id && $0.state != .uploading }
    }

    /// Drop every row and clear the banner.
    public func clear() {
        attachments.removeAll { $0.state != .uploading }
        if attachments.isEmpty { error = nil }
    }

    /// Drop uploaded rows after a send (failed/tooLarge stay for action).
    public func clearFinished() {
        attachments.removeAll { $0.state == .uploaded }
    }

    /// Dismiss the composer error banner.
    public func clearError() {
        error = nil
    }

    /// Re-arm a failed row to .staged for another Send. No-op otherwise.
    public func retry(id: String) {
        guard let i = attachments.firstIndex(where: { $0.id == id }),
              case .failed = attachments[i].state
        else { return }
        attachments[i].state = .staged
    }

    /// Rows ready to upload (cap-gated, in pick order).
    public var staged: [ComposeAttachment] {
        attachments.filter { $0.state == .staged }
    }

    /// True when Send has files to upload (enables Send with an empty draft).
    public var hasStaged: Bool {
        attachments.contains { $0.state == .staged }
    }

    /// Upload every staged file via the existing files-upload path, in pick
    /// order, skipping .tooLarge/.failed/.uploaded rows (the fetcher is never
    /// called for them). Failures mark the row and set `error` but don't stop
    /// later files. Demo mode fabricates success without touching core.
    /// Returns the uploaded files (demo-fabricated or core-echoed).
    @discardableResult
    public func uploadPending(chatID: String, isDemo: Bool = false) async -> [SharedFile] {
        let pending = staged
        guard !pending.isEmpty, !uploading else { return [] }
        uploading = true
        defer { uploading = false }
        var done: [SharedFile] = []
        for item in pending {
            setState(id: item.id, .uploading)
            if isDemo {
                setState(id: item.id, .uploaded)
                done.append(SharedFile(
                    id: "demo-up-\(item.name)", name: item.name, size: item.size))
                continue
            }
            do {
                let fetcher = uploadFetcher
                let path = item.path
                let resp = try await Task.detached { try fetcher(chatID, path) }.value
                setState(id: item.id, .uploaded)
                done.append(resp.file)
            } catch {
                let msg = SharedFilesStore.message(for: error)
                setState(id: item.id, .failed(msg))
                self.error = msg
            }
        }
        return done
    }

    private func setState(id: String, _ state: ComposeAttachmentState) {
        guard let i = attachments.firstIndex(where: { $0.id == id }) else { return }
        attachments[i].state = state
    }
}
