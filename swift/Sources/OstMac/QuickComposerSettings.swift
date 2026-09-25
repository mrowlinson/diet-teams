// QuickComposerSettings.swift — f1-composer lane: Settings → Chats →
// Quick Composer section (enable toggle + click-to-record hotkey +
// reset). Native controls only. Remap/toggle/reset take effect without
// a relaunch via .quickComposePrefsChanged (AppState re-registers);
// prefs persist in UserDefaults (`om.quickcompose.*`).
import AppKit
import DietDesign
import OstMacCore
import SwiftUI

/// Click-to-record capture state (reference type: the NSEvent monitor
/// closure outlives any one View value).
final class QuickComposeRecorder: ObservableObject {
    @Published var combo = QuickComposerPrefs.loadCombo()
    @Published var capturing = false
    @Published var rejection: String?
    private var monitor: Any?

    /// Re-read the persisted combo (reset posts prefsChanged, which the
    /// section turns into this).
    func reload() {
        combo = QuickComposerPrefs.loadCombo()
    }

    func start() {
        rejection = nil
        capturing = true
        stopMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
            return nil // swallow while capturing: no stray activation
        }
    }

    func stop() {
        stopMonitor()
        capturing = false
    }

    private func stopMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func handle(_ event: NSEvent) {
        let held = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == 53, held.isEmpty {
            stop() // bare Esc cancels the capture
            return
        }
        let combo = QuickComposeCombo(
            keyCode: UInt32(event.keyCode),
            modifiers: QuickComposeCombo.carbonModifiers(cocoaFlags: event.modifierFlags.rawValue))
        if let reason = combo.rejectedReason {
            rejection = reason // stay capturing so they can retry
            return
        }
        QuickComposerPrefs.saveCombo(combo)
        self.combo = combo
        rejection = nil
        stop()
        NotificationCenter.default.post(name: .quickComposePrefsChanged, object: nil)
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}

struct QuickComposerSettingsSection: View {
    @AppStorage("om.quickcompose.enabled") private var enabled = true
    @StateObject private var recorder = QuickComposeRecorder()

    var body: some View {
        Section("Quick Composer") {
            Toggle("Enable global hotkey", isOn: $enabled)
                .onChange(of: enabled) {
                    NotificationCenter.default.post(name: .quickComposePrefsChanged, object: nil)
                }
            HStack {
                Text("Hotkey")
                Spacer()
                Button(recorder.capturing ? "Press keys…" : recorder.combo.displayString) {
                    recorder.start()
                }
                .buttonStyle(.bordered)
                .disabled(!enabled || recorder.capturing)
                .help("Click, then press a key combination")
            }
            if recorder.capturing {
                Text("Press a key combination. Esc cancels.")
                    .font(DietType.caption1)
                    .foregroundStyle(DietColor.textSecondaryColor)
            }
            if let rejection = recorder.rejection {
                Text(rejection)
                    .font(DietType.caption1)
                    .foregroundStyle(Color(nsColor: DietColor.warning))
            }
            Button("Reset to default (⌃⌘M)") {
                QuickComposerPrefs.saveCombo(.default)
                recorder.reload()
                recorder.rejection = nil
                NotificationCenter.default.post(name: .quickComposePrefsChanged, object: nil)
            }
            .disabled(recorder.combo == .default)
            Text("Summons a floating quick message from any app while Better Teams runs — backgrounded, windows closed, anywhere. Plain text; ⌘⏎ sends.")
                .font(DietType.caption1)
                .foregroundStyle(DietColor.textSecondaryColor)
        }
        .onReceive(NotificationCenter.default.publisher(for: .quickComposePrefsChanged)) { _ in
            recorder.reload()
        }
        .onDisappear { recorder.stop() }
    }
}
