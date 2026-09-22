// LiveVideoModel.swift — om-liveav: incoming-AU poll + VT decode for display.
// Drains the Rust incoming queue on a detached loop (250ms), decodes AUs on
// the same serial path, publishes the latest frame on-main.
import SwiftUI

@MainActor
public final class LiveVideoModel: ObservableObject {
    @Published public private(set) var remoteImage: CGImage?
    @Published public private(set) var status = "idle"
    @Published public private(set) var frames = 0
    @Published public private(set) var running = false

    private var generation = 0

    public init() {}

    public func start() {
        guard !running else { return }
        running = true
        status = "waiting for video…"
        generation += 1
        let gen = generation
        Task.detached(priority: .userInitiated) { [weak self] in
            let decoder = H264StreamDecoder()
            while await MainActor.run(body: { [weak self] in
                self != nil && gen == self!.generation
            }) {
                try? await Task.sleep(nanoseconds: 250_000_000)
                let alive = await MainActor.run(body: { [weak self] in
                    self != nil && gen == self!.generation
                })
                guard alive else { return }
                do {
                    let poll = try RustCore.videoPollIncoming()
                    guard let au = poll.au else { continue }
                    let nals = au.nals.compactMap { Data(base64Encoded: $0) }
                    guard nals.count == au.nals.count else { continue }
                    if let img = try decoder.decode(nals: nals) {
                        await MainActor.run { [weak self] in
                            guard let self, gen == self.generation else { return }
                            self.remoteImage = img
                            self.frames += 1
                            self.status = "\(img.width)x\(img.height) live"
                        }
                    }
                } catch is CancellationError {
                    return
                } catch {
                    await MainActor.run { [weak self] in
                        guard let self, gen == self.generation else { return }
                        self.status = "decode: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    public func stop() {
        generation += 1
        running = false
        status = "stopped"
    }
}
