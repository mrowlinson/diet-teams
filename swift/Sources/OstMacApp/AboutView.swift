// AboutView.swift — om-package lane: About OstMac window content.
import AppKit
import SwiftUI

public struct AboutView: View {
    public init() {}

    public var body: some View {
        VStack(spacing: 10) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 64, height: 64)
            }
            Text(AppIdentity.name)
                .font(.title).bold()
            Text("Version \(AppIdentity.version)")
                .foregroundStyle(.secondary)
            Text(AppIdentity.bundleID)
                .font(.caption).monospaced()
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("\(AppIdentity.tagline) — chat list, conversation, live updates.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 340)
    }
}
