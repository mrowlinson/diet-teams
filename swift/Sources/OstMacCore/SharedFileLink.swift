// SharedFileLink.swift — om-i1-links lane: copy-link control for Shared rows.
//
// Pure button subview: spinner while the store fetches the createLink
// URL, "Copy link" otherwise (linked rows show a checkmark and re-copy
// the cached URL without refetching). Fetch + pasteboard write live in
// SharedFilesStore.shareLink (injected link/copy seams); this file only
// renders state, so previews and tests never touch FFI or pasteboard.
//
//   SharedFileLinkButton(linking: false, linked: true) { store.shareLink(file) }
import SwiftUI

/// Copy-link helpers. No view or FFI code.
public enum SharedFileLink {
    /// Stable fabricated link for demo rows (offline, no core).
    public static func demoLink(for fileID: String) -> String {
        "https://demo.sharepoint.local/:i:/r/\(fileID)?sharing=org"
    }
}

/// Copy-link control for one Shared row.
public struct SharedFileLinkButton: View {
    public let linking: Bool
    public let linked: Bool
    public let onTap: () -> Void

    public init(linking: Bool = false, linked: Bool = false, onTap: @escaping () -> Void = {}) {
        self.linking = linking
        self.linked = linked
        self.onTap = onTap
    }

    public var body: some View {
        if linking {
            ProgressView().controlSize(.small)
                .help("Creating sharing link…")
        } else {
            Button(action: onTap) {
                Label("Copy link", systemImage: linked ? "checkmark" : "link")
            }
            .buttonStyle(.link)
            .font(.caption)
            .help(linked
                ? "Copy the sharing link again"
                : "Create a view-only sharing link and copy it")
        }
    }
}
