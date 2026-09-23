// LiveVideoView.swift — om-liveav: remote live-video frame + status.
// om-reskin-call: DietDesign tile (control radius, divider ring,
// caption scale, mono counts).
import DietDesign
import SwiftUI

/// Remote video tile. Starts/stops the poll loop with visibility.
public struct LiveVideoView: View {
    @StateObject private var model = LiveVideoModel()

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: DietSpace.xs) {
            ZStack {
                Rectangle().fill(.black.opacity(0.85))
                if let img = model.remoteImage {
                    Image(img, scale: 1, label: Text("Remote video"))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Text(model.status)
                        .font(DietType.caption1)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .frame(width: 320, height: 240)
            .clipShape(RoundedRectangle(cornerRadius: DietRadius.control))
            .overlay(
                RoundedRectangle(cornerRadius: DietRadius.control)
                    .stroke(DietColor.dividerColor))
            Text("remote · \(model.status) · \(model.frames) frames")
                .font(DietType.captionMono)
                .foregroundStyle(DietColor.textSecondaryColor)
        }
        .task { model.start() }
        .onDisappear { model.stop() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Remote video")
    }
}
