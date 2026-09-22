// LiveVideoView.swift — om-liveav: remote live-video frame + status.
import SwiftUI

/// Remote video tile. Starts/stops the poll loop with visibility.
public struct LiveVideoView: View {
    @StateObject private var model = LiveVideoModel()

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                Rectangle().fill(.black.opacity(0.85))
                if let img = model.remoteImage {
                    Image(img, scale: 1, label: Text("Remote video"))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Text(model.status)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .frame(width: 320, height: 240)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(.secondary.opacity(0.5)))
            Text("remote · \(model.status) · \(model.frames) frames")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task { model.start() }
        .onDisappear { model.stop() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Remote video")
    }
}
