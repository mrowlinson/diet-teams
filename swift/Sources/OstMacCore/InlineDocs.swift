// InlineDocs.swift — om-inline-docs lane: doc rows inside bubbles.
//
// File-share messages arrive as bare `<attachment id="GUID">` refs: the
// name/size/URL live in Graph, not in the message (the task's assumption
// that messages carry docs is wrong for the wire format — see below).
// Core exposes the same GUID on each shared file (`attachment_id`, mined
// from the driveItem eTag), so the bubble resolves refs against the
// already-loaded Shared tab list and renders one native row per match:
// Finder icon (async) + name + size + Open. No bytes are ever prefetched:
// resolution is a pure in-memory match, the icon comes from the local
// system icon cache, and Open hands the SharePoint URL to the browser.
//
//   let docs = InlineDocs.docs(for: message, files: sharedFiles)
//   InlineDocRows(docs: docs, onOpen: { shared.open($0.file) })
import AppKit
import Foundation
import SwiftUI

/// One resolved doc row: a shared file matched to a message's attachment
/// ref. `id` is the file id (stable across re-resolves); `refID` is the
/// `<attachment id>` that matched it.
public struct InlineDoc: Sendable, Equatable, Identifiable {
    public var id: String { file.id }
    public let file: SharedFile
    public let refID: String

    public init(file: SharedFile, refID: String) {
        self.file = file
        self.refID = refID
    }

    public var name: String { file.name }
    public var sizeLabel: String { file.sizeLabel }
    public var iconName: String { file.iconName }
    public var sender: String? { file.sender }
}

public enum InlineDocs {
    /// Max rows per bubble (caps a hostile blob; bot-post parity).
    public static let maxRows = 10

    /// Attachment ids referenced by one message's raw HTML, in order,
    /// deduped. Only blocks WITH an `id` attribute qualify: id-less
    /// blocks stay bot-post-only (no row duplication). Unterminated and
    /// self-closing forms are handled; id-less/empty ids are dropped.
    /// Tag/attr names are case-insensitive; values tolerate any quoting
    /// (same `attributes(of:)` parser the image miner uses).
    public static func refs(fromRaw raw: String?) -> [String] {
        guard let raw, !raw.isEmpty else { return [] }
        var out: [String] = []
        var seen = Set<String>()
        var rest = raw[...]
        while let s = rest.range(of: "<attachment", options: .caseInsensitive),
              let gt = rest[s.upperBound...].firstIndex(of: ">")
        {
            let open = String(rest[s.lowerBound ... gt])
            if open.hasSuffix("/>") {
                rest = rest[rest.index(after: gt)...]
            } else {
                guard let e = rest[gt...].range(of: "</attachment>", options: .caseInsensitive) else {
                    break // unterminated: kept as text, never a ref
                }
                rest = rest[e.upperBound...]
            }
            let id = (MessageRender.attributes(of: open)["id"] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, seen.insert(id).inserted else { continue }
            out.append(id)
        }
        return out
    }

    /// Pure in-memory match: each ref against the already-loaded shared
    /// list by `attachment_id`. Unmatched refs are dropped (the bubble
    /// falls back to existing text/placeholder behavior). Performs no
    /// I/O: safe to call on every render.
    public static func resolve(refs: [String], files: [SharedFile]) -> [InlineDoc] {
        var out: [InlineDoc] = []
        for id in refs {
            guard out.count < maxRows else { break }
            guard let f = files.first(where: { $0.attachment_id == id }) else { continue }
            out.append(InlineDoc(file: f, refID: id))
        }
        return out
    }

    /// Rows for one bubble: mine the refs, resolve against loaded files.
    public static func docs(for message: ChatMessage, files: [SharedFile]) -> [InlineDoc] {
        resolve(refs: refs(fromRaw: message.raw), files: files)
    }

    /// True when any message carries doc refs: the host preloads the
    /// shared list (metadata only, never bytes) so rows can resolve.
    /// Chats without refs never trigger a load (no prefetch).
    public static func shouldPreload(messages: [ChatMessage]) -> Bool {
        messages.contains { !refs(fromRaw: $0.raw).isEmpty }
    }

    /// Parsed http(s) Open target (SharePoint page), or nil for rows
    /// without one. Only http(s) schemes open (bot-row parity).
    public static func openTarget(for doc: InlineDoc) -> URL? {
        guard let s = doc.file.web_url, let url = URL(string: s),
              url.scheme == "http" || url.scheme == "https"
        else { return nil }
        return url
    }

    /// Default Open: browser-preview the SharePoint page. Never downloads
    /// (bytes move only via the Shared tab's explicit Save).
    public static func open(_ doc: InlineDoc) {
        if let url = openTarget(for: doc) {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Cached Finder file icons by extension (om-inline-docs): the row's
/// thumbnail. Local system-icon lookup only — never network. The actor
/// memoizes per extension so scrolling never re-queries.
public actor InlineDocIconCache {
    public static let shared = InlineDocIconCache()

    private var cache: [String: NSImage] = [:]

    /// Icon for one filename. Runs on the main actor (AppKit affinity);
    /// callers show their SF Symbol fallback until it lands.
    public func icon(fileName: String) async -> NSImage {
        let key = (fileName as NSString).pathExtension.lowercased()
        if let hit = cache[key] { return hit }
        let img = await MainActor.run {
            NSWorkspace.shared.icon(forFileType: key.isEmpty ? "___" : key)
        }
        cache[key] = img
        return img
    }
}

/// Finder icon with SF Symbol fallback: paints the fallback instantly,
/// swaps in the real file icon when the (local, cached) lookup lands.
/// Fixed frame, so the swap never shifts the timeline.
struct InlineDocIcon: View {
    let fileName: String
    let fallback: String
    @State private var nsImage: NSImage?

    var body: some View {
        Group {
            if let nsImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: fallback)
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 28, height: 28)
        .task(id: fileName) {
            nsImage = await InlineDocIconCache.shared.icon(fileName: fileName)
        }
    }
}

/// Native doc rows for one bubble: Finder icon + name + size + Open.
/// Open previews in the browser; nothing downloads until the Shared
/// tab's explicit Save.
public struct InlineDocRows: View {
    public let docs: [InlineDoc]
    public var onOpen: (InlineDoc) -> Void

    public init(
        docs: [InlineDoc],
        onOpen: @escaping (InlineDoc) -> Void = { InlineDocs.open($0) }
    ) {
        self.docs = docs
        self.onOpen = onOpen
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(docs) { doc in
                InlineDocRow(doc: doc, onOpen: { onOpen(doc) })
            }
        }
    }
}

struct InlineDocRow: View {
    let doc: InlineDoc
    var onOpen: () -> Void = {}

    var body: some View {
        HStack(spacing: 10) {
            InlineDocIcon(fileName: doc.name, fallback: doc.iconName)
            VStack(alignment: .leading, spacing: 2) {
                Text(doc.name)
                    .font(.body)
                    .lineLimit(1)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    Text(doc.sizeLabel)
                        .font(.caption).monospaced()
                        .foregroundStyle(.secondary)
                    if let sender = doc.sender {
                        Text("· \(sender)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 8)
            if InlineDocs.openTarget(for: doc) != nil {
                Button("Open", action: onOpen)
                    .buttonStyle(.link)
                    .font(.caption)
                    .help("Open in SharePoint (browser)")
            }
        }
        .padding(8)
        .background(Color.gray.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("\(doc.name), \(doc.sizeLabel)")
    }
}
