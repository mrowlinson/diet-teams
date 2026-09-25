// GifPlayer.swift — om-gif-playback: bubble player + shared playhead state.
//
// The bubble plays the decoded clip through a native TimelineView tick
// (no custom timers); a native Play/Pause overlay toggles it. The zoom
// viewer reuses GifPlayerState for the same clip at full-res. Reduce
// Motion opens paused on the still first frame; pressing play is
// explicit user intent and animates either way.
import AppKit
import DietDesign
import SwiftUI

/// Playhead state shared by the bubble player and the zoom viewer.
/// Wall-time driven: views feed TimelineView dates into `tick`.
@MainActor
public final class GifPlayerState: ObservableObject {
    @Published public private(set) var playing: Bool
    /// Seconds into the loop; frozen while paused.
    @Published public private(set) var playhead: Double = 0
    private var lastTick: Date?

    public init(playing: Bool) {
        self.playing = playing
    }

    public func toggle() {
        playing.toggle()
        lastTick = nil // resume without a jump
    }

    /// Advance the playhead by wall time, wrapping the loop. While
    /// paused the playhead freezes (the still stays up); degenerate
    /// loops just restamp.
    public func tick(now: Date, totalDuration: Double) {
        guard playing, totalDuration > 0 else {
            lastTick = now
            return
        }
        if let last = lastTick {
            let dt = now.timeIntervalSince(last)
            if dt > 0 {
                playhead = (playhead + dt)
                    .truncatingRemainder(dividingBy: totalDuration)
            }
        }
        lastTick = now
    }

    /// Reduce Motion pauses on the still; turning it off resumes
    /// autoplay. A manual toggle sticks until the setting changes again.
    public func applyReduceMotion(_ reduceMotion: Bool) {
        playing = GifPlayback.initiallyPlaying(
            animated: true, reduceMotion: reduceMotion)
        lastTick = nil
    }
}

/// Animated bubble: looping clip with a native play/stop overlay.
/// Tap (outside the overlay) expands to the zoom viewer, like stills.
public struct GifPlayerView: View {
    private let clip: GifClip
    private let still: NSImage
    private let url: String
    private let messageID: String
    private let alt: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var state = GifPlayerState(playing: true)
    @State private var expanded = false

    public init(
        clip: GifClip, still: NSImage,
        url: String, messageID: String, alt: String
    ) {
        self.clip = clip
        self.still = still
        self.url = url
        self.messageID = messageID
        self.alt = alt
    }

    private var frame: NSImage {
        guard !clip.frames.isEmpty else { return still }
        return clip.frames[GifClip.frameIndex(
            at: state.playhead, durations: clip.durations)]
    }

    public var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Button { expanded = true } label: {
                Group {
                    if state.playing {
                        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tick in
                            Image(nsImage: frame)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(
                                    maxWidth: RemoteImageSlot.width,
                                    maxHeight: RemoteImageSlot.height)
                                .onChange(of: tick.date) { _, now in
                                    state.tick(
                                        now: now,
                                        totalDuration: clip.totalDuration)
                                }
                        }
                    } else {
                        Image(nsImage: still)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(
                                maxWidth: RemoteImageSlot.width,
                                maxHeight: RemoteImageSlot.height)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: DietRadius.control))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(alt.isEmpty ? "Animated image" : alt)
            .sheet(isPresented: $expanded) {
                ZoomedImage(
                    thumb: still, url: url,
                    messageID: messageID, alt: alt)
            }
            Button(state.playing ? "Pause" : "Play") { state.toggle() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel(
                    state.playing ? "Pause GIF" : "Play GIF")
                .padding(DietSpace.xs)
        }
        .onAppear { state.applyReduceMotion(reduceMotion) }
        .onChange(of: reduceMotion) { _, rm in state.applyReduceMotion(rm) }
    }
}
