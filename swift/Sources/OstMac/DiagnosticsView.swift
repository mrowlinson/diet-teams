// DiagnosticsView.swift — om-statusbar lane: the Diagnostics window
// (Window ▸ Diagnostics, `--show-diagnostics` shot hook). Holds every
// counter the slim status bar dropped (core, session, feed counts, call
// test buttons), so the bar itself is just the Live dot + errors.
// om-settings-trim: also hosts token health (moved from Settings).
// Native grouped Form + LabeledContent throughout.

import DietDesign
import OstMacChatList
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
                NotificationsDiagRow(
                    unread: state.unread, mentions: state.mentions,
                    quiet: state.quiet,
                    breakthroughs: state.mentionBreakthroughs,
                    dnd: state.mentionDNDSuppressions,
                    quietSuppressions: state.mentionQuietSuppressions)
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
            Section("Meetings") {
                MeetingsDiagRow(store: state.meetings)
            }
            Section("Meeting") {
                MeetingDiagRow(roster: state.meeting, chat: state.meetingChat, events: state.feedRoster)
            }
            Section("Screen share") {
                ShareDiagRow(store: state.screenShare)
            }
            Section("Image preload") {
                PreloadDiagRow(store: ImagePreloadStore.shared)
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

/// Meetings counters row (om-meet-join): observes the store so the
/// counts tick as meetings load and joins start.
struct MeetingsDiagRow: View {
    @ObservedObject var store: MeetingsViewModel

    var body: some View {
        LabeledContent(
            "Upcoming",
            value: DiagnosticsFormat.meetingsLine(
                fetched: store.fetchedCount, joins: store.joinCount,
                lobby: store.lobby.rawValue))
            .textSelection(.enabled)
    }
}

/// Screen-share counters row (om-screenshare): observes the shared
/// model so the counts tick while sharing. The only place share
/// numbers appear — the tile shows status words only.
struct ShareDiagRow: View {
    @ObservedObject var store: ScreenShareModel

    var body: some View {
        LabeledContent(
            "Sharing",
            value: DiagnosticsFormat.shareLine(
                source: store.phase.isLive ? store.sourceLabel : nil,
                frames: store.framesCaptured,
                sent: store.framesSent))
            .textSelection(.enabled)
    }
}

/// Prefetch counters row (om-imgpreload): observes the shared store
/// so the counts tick as the reader scrolls.
struct PreloadDiagRow: View {
    @ObservedObject var store: ImagePreloadStore

    var body: some View {
        LabeledContent(
            "Images",
            value: DiagnosticsFormat.preloadLine(
                prefetched: store.stats.prefetched, hits: store.stats.hits,
                cancelled: store.stats.cancelled, inFlight: store.stats.inFlight))
            .textSelection(.enabled)
    }
}

/// Notification counters row (om-mention-alerts): mention threads
/// (the Mentions row filter source, also the Dock number), unread
/// totals, breakthrough/suppression counts, quiet-hours state. The only
/// place these numbers appear — banners never show counts.
struct NotificationsDiagRow: View {
    @ObservedObject var unread: UnreadStore
    @ObservedObject var mentions: MentionStore
    @ObservedObject var quiet: QuietHoursStore
    let breakthroughs: Int
    let dnd: Int
    let quietSuppressions: Int

    var body: some View {
        LabeledContent(
            "Mentions",
            value: DiagnosticsFormat.mentionsLine(count: mentions.count))
            .textSelection(.enabled)
        LabeledContent(
            "Unread",
            value: DiagnosticsFormat.unreadLine(
                total: unread.total, chats: unread.counts.count))
            .textSelection(.enabled)
        LabeledContent(
            "Alerts",
            value: DiagnosticsFormat.mentionAlertsLine(
                breakthroughs: breakthroughs, dnd: dnd,
                quiet: quietSuppressions))
            .textSelection(.enabled)
        LabeledContent(
            "Quiet",
            value: DiagnosticsFormat.quietLine(
                summary: quiet.hours.summary,
                active: quiet.isActiveNow()))
            .textSelection(.enabled)
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

/// Meeting counters row (om-meet-chat): roster + persisted-thread
/// counts live here only (the Meeting window shows no numbers).
struct MeetingDiagRow: View {
    @ObservedObject var roster: MeetingRosterStore
    @ObservedObject var chat: MeetingChatStore
    let events: Int

    var body: some View {
        LabeledContent(
            "Roster",
            value: DiagnosticsFormat.rosterLine(
                events: events, active: roster.activeCount,
                speaking: roster.speakingCount, muted: roster.mutedCount))
            .textSelection(.enabled)
        LabeledContent(
            "Thread",
            value: chat.threadID == nil
                ? "none"
                : DiagnosticsFormat.meetingThreadLine(
                    messages: chat.messages.count, live: chat.meetingActive))
            .textSelection(.enabled)
    }
}
