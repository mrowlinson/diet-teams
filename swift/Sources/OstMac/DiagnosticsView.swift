// DiagnosticsView.swift — om-statusbar lane: the Diagnostics window
// (Window ▸ Diagnostics, `--show-diagnostics` shot hook). Holds every
// counter the slim status bar dropped (core, session, feed counts, call
// test buttons), so the bar itself is just the Live dot + errors.
// om-settings-trim: also hosts token health (moved from Settings).
// Native grouped Form + LabeledContent throughout.

import DietDesign
import OstMacCore
import SwiftUI

struct DiagnosticsView: View {
    @EnvironmentObject private var state: AppState
    // Token health moved here from Settings (om-settings-trim): one
    // diagnostics home. Manual Run check only (never auto-fires).
    @StateObject private var health = HealthStore()

    var body: some View {
        Form {
            Section("Token health") {
                HealthView(store: health)
            }
            Section("Core") {
                LabeledContent(
                    "Version",
                    value: DiagnosticsFormat.coreLine(
                        version: state.coreVersion, initCode: state.initCode))
                    .textSelection(.enabled)
            }
            Section("Session") {
                LabeledContent(
                    "Status",
                    value: DiagnosticsFormat.sessionLine(
                        isDemo: state.isDemo, signedIn: state.signedIn))
                LabeledContent("Presence") {
                    PresencePicker(store: state.presence)
                }
            }
            Section("Realtime feed") {
                LabeledContent(
                    "State",
                    value: DiagnosticsFormat.feedLine(
                        state: state.feedState, events: state.feedEvents,
                        polls: state.feedPolls, resyncs: state.feedResyncs))
                    .textSelection(.enabled)
                TypingDiagRow(store: state.typing, events: state.feedTyping)
                if let err = state.feedError {
                    LabeledContent("Last error") {
                        Text(err)
                            .font(DietType.caption1)
                            .foregroundStyle(Color(nsColor: DietColor.danger))
                            .textSelection(.enabled)
                    }
                }
            }
            Section("Read receipts") {
                LabeledContent(
                    "Positions",
                    value: DiagnosticsFormat.receiptsLine(
                        sent: state.receipts.sentCount,
                        threads: state.receipts.threadCount,
                        peers: state.receipts.receiptCount))
                    .textSelection(.enabled)
                if let err = state.receipts.lastError {
                    LabeledContent("Last error") {
                        Text(err)
                            .font(DietType.caption1)
                            .foregroundStyle(Color(nsColor: DietColor.danger))
                            .textSelection(.enabled)
                    }
                }
            }
            Section("Call") {
                callRow
                LabeledContent(
                    "Recent",
                    value: DiagnosticsFormat.callsLine(
                        total: state.history.totalCount,
                        missed: state.history.missedCount))
                    .textSelection(.enabled)
                if let err = state.call.error {
                    LabeledContent("Last error") {
                        Text(err)
                            .font(DietType.caption1)
                            .foregroundStyle(Color(nsColor: DietColor.danger))
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 360)
        .navigationTitle("Diagnostics")
    }

    /// Active call one-liner, else the echo test buttons (live signed-in
    /// only) — both moved verbatim from the old status bar.
    /// om-call-ux: phase + session counters (Diagnostics is the only
    /// place counters live) + the never-trap escape hatch: a dismissed
    /// ring stays actionable here (Accept/Decline/Recall), ended
    /// records Clear back to idle.
    @ViewBuilder
    private var callRow: some View {
        if let c = state.call.call, c.isActive {
            LabeledContent(
                "Active",
                value: "call: \(c.state) · \(c.displayPeer)")
                .textSelection(.enabled)
            callEscapeHatch(for: c)
        } else if state.call.phase == .ended {
            LabeledContent("Active", value: "ended (\(state.call.lastAction))")
                .foregroundStyle(DietColor.textSecondaryColor)
            Button("Clear") { state.call.clearEnded() }
                .buttonStyle(.bordered)
        } else if !state.isDemo, state.signedIn == true {
            HStack {
                Button("Echo test") { state.call.echo() }
                    .disabled(state.call.busy)
                    .help("Place the echo-bot test call (signaling only)")
                Button("Echo live") { state.call.echoLive() }
                    .disabled(state.call.busy)
                    .help("Place the echo-bot test call with live audio/video")
            }
        } else {
            LabeledContent("Active", value: "no call")
                .foregroundStyle(DietColor.textSecondaryColor)
        }
        LabeledContent(
            "Phase",
            value: "\(state.call.phase.rawValue) · last: \(state.call.lastAction.isEmpty ? "—" : state.call.lastAction)")
            .textSelection(.enabled)
        LabeledContent(
            "Session",
            value: "rings \(state.call.rings) · accepts \(state.call.accepts) · declines \(state.call.declines) · dismissals \(state.call.dismissals) · timeouts \(state.call.timeouts)")
            .textSelection(.enabled)
        LabeledContent(
            "Controls",
            value: "muted \(state.call.muted ? "yes" : "no") · camera \(state.call.cameraOn ? "on" : "off") · speaker \(state.call.speaker ?? "default")")
            .textSelection(.enabled)
    }

    /// Dismissed-but-live calls stay actionable here so dismissing the
    /// banner never strands a ring; live calls get the same actions.
    @ViewBuilder
    private func callEscapeHatch(for c: CallInfo) -> some View {
        let dismissed = state.call.dismissedIDs.contains(c.id)
        if dismissed {
            LabeledContent("Banner", value: "dismissed (actions below still work)")
                .foregroundStyle(DietColor.textSecondaryColor)
        }
        if c.dir == "in", c.state == "ringing" {
            HStack {
                Button("Accept live") { state.call.acceptLive() }
                    .disabled(state.call.busy)
                Button("Accept") { state.call.accept() }
                    .disabled(state.call.busy)
                Button("Decline") { state.call.end() }
                    .disabled(state.call.busy)
                if dismissed {
                    Button("Recall banner") { state.call.recall() }
                }
            }
            .buttonStyle(.bordered)
        } else {
            HStack {
                Button("End") { state.call.end() }
                    .disabled(state.call.busy)
                if dismissed {
                    Button("Recall banner") { state.call.recall() }
                }
            }
            .buttonStyle(.bordered)
        }
    }
}

/// Typing counters row (om-typing): observes the store so the live
/// count ticks as indicators arrive and expire.
struct TypingDiagRow: View {
    @ObservedObject var store: TypingStore
    let events: Int

    var body: some View {
        LabeledContent(
            "Typing",
            value: DiagnosticsFormat.typingLine(
                events: events, active: store.activeCount))
            .textSelection(.enabled)
    }
}
