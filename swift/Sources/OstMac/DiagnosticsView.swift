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

    /// e2-attention shot: Quiet hours section alone at the top (Form
    /// owns its scroller — no scroll API reaches it, proven by shot).
    private static var isAttentionShot: Bool {
        CommandLine.arguments.contains("--show-settings-attention")
    }

    var body: some View {
        Form {
            if !Self.isAttentionShot {
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
                        breakthroughs: state.mentionBreakthroughs,
                        dnd: state.mentionDNDSuppressions,
                        quietSuppressions: state.mentionQuietSuppressions)
                    LabeledContent(
                        "Notifications",
                        value: DiagnosticsFormat.notifLine(
                            posted: state.notifPosted, skipped: state.notifSkipped,
                            lastReason: state.notifLastReason))
                        .textSelection(.enabled)
                    if let err = state.feedError {
                        LabeledContent("Last error") {
                            Text(err)
                                .font(DietType.caption1)
                                .foregroundStyle(Color(nsColor: DietColor.danger))
                                .textSelection(.enabled)
                        }
                    }
                }
                Section("Offline search") {
                    LabeledContent(
                        "Index",
                        value: "\(state.searchIndexDocs) docs" + (state.messageSearch.offlineMs.map {
                            String(format: " · last local %.1fms", $0)
                        } ?? ""))
                        .textSelection(.enabled)
                    LabeledContent(
                        "Last source",
                        value: state.messageSearch.source.rawValue)
                        .textSelection(.enabled)
                    if let err = state.searchIndexError {
                        LabeledContent("Last error") {
                            Text(err)
                                .font(DietType.caption1)
                                .foregroundStyle(Color(nsColor: DietColor.danger))
                                .textSelection(.enabled)
                        }
                    }
                }
                Section("Read receipts") {
                    ReceiptsDiagRow(store: state.receipts)
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
            }
            Section("Quiet hours") {
                QuietHoursDiagRow(
                    store: state.quietHours, focus: state.focusSync,
                    sched: state.presenceSchedule)
            }
            if !Self.isAttentionShot {
                Section("Chat list") {
                    PinsDiagRow(chats: state.chats)
                }
                Section("Leave & block") {
                    LeaveBlockDiagRow(chats: state.chats, blocked: state.blocked)
                }
                Section("Call") {
                    CallDiagRows(
                        call: state.call, history: state.history,
                        isDemo: state.isDemo, signedIn: state.signedIn)
                }
                Section("Ghost mode") {
                    GhostDiagRow(store: state.ghost)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 360)
        .navigationTitle("Diagnostics")
    }
}

/// Read-receipt rows (om-s7-tickstorm): observes the store directly so
/// the counts tick without an AppState forward.
struct ReceiptsDiagRow: View {
    @ObservedObject var store: ReceiptStore

    var body: some View {
        LabeledContent(
            "Positions",
            value: DiagnosticsFormat.receiptsLine(
                sent: store.sentCount,
                threads: store.threadCount,
                peers: store.receiptCount))
            .textSelection(.enabled)
        if let err = store.lastError {
            LabeledContent("Last error") {
                Text(err)
                    .font(DietType.caption1)
                    .foregroundStyle(Color(nsColor: DietColor.danger))
                    .textSelection(.enabled)
            }
        }
    }
}

/// Ghost-mode row (f1-ghost): observes the store directly so the
/// state and suppressed/held counts tick without an AppState
/// forward. The ONLY surface for the counters.
struct GhostDiagRow: View {
    @ObservedObject var store: GhostStore

    var body: some View {
        LabeledContent(
            "State",
            value: DiagnosticsFormat.ghostLine(
                master: store.master,
                receipts: store.suppressReceipts,
                presence: store.suppressPresence,
                suppressed: store.suppressedReceipts,
                held: store.heldPresence))
            .textSelection(.enabled)
    }
}

/// User-pin row (om-s7-tickstorm): observes the chat list directly so
/// the count ticks without an AppState forward.
struct PinsDiagRow: View {
    @ObservedObject var chats: ChatListViewModel

    var body: some View {
        LabeledContent(
            "User pins",
            value: DiagnosticsFormat.pinsLine(
                count: chats.pins.count))
            .textSelection(.enabled)
    }
}

/// Call rows (om-s7-tickstorm): observes the call + history stores
/// directly so phases/counters tick without an AppState forward.
struct CallDiagRows: View {
    @ObservedObject var call: CallStore
    @ObservedObject var history: CallHistoryStore
    let isDemo: Bool
    let signedIn: Bool?

    var body: some View {
        callRow
        LabeledContent(
            "Recent",
            value: DiagnosticsFormat.callsLine(
                total: history.totalCount,
                missed: history.missedCount))
            .textSelection(.enabled)
        if let err = call.error {
            LabeledContent("Last error") {
                Text(err)
                    .font(DietType.caption1)
                    .foregroundStyle(Color(nsColor: DietColor.danger))
                    .textSelection(.enabled)
            }
        }
    }

    /// Active call one-liner, else the echo test buttons (live signed-in
    /// only) — both moved verbatim from the old status bar.
    /// om-call-ux: phase + session counters (Diagnostics is the only
    /// place counters live) + the never-trap escape hatch: a dismissed
    /// ring stays actionable here (Accept/Decline/Recall), ended
    /// records Clear back to idle.
    @ViewBuilder
    private var callRow: some View {
        if let c = call.call, c.isActive {
            LabeledContent(
                "Active",
                value: "call: \(c.state) · \(c.displayPeer)")
                .textSelection(.enabled)
            callEscapeHatch(for: c)
        } else if call.phase == .ended {
            LabeledContent("Active", value: "ended (\(call.lastAction))")
                .foregroundStyle(DietColor.textSecondaryColor)
            Button("Clear") { call.clearEnded() }
                .buttonStyle(.bordered)
        } else if !isDemo, signedIn == true {
            HStack {
                Button("Echo test") { call.echo() }
                    .disabled(call.busy)
                    .help("Place the echo-bot test call (signaling only)")
                Button("Echo live") { call.echoLive() }
                    .disabled(call.busy)
                    .help("Place the echo-bot test call with live audio/video")
            }
        } else {
            LabeledContent("Active", value: "no call")
                .foregroundStyle(DietColor.textSecondaryColor)
        }
        LabeledContent(
            "Phase",
            value: "\(call.phase.rawValue) · last: \(call.lastAction.isEmpty ? "—" : call.lastAction)")
            .textSelection(.enabled)
        LabeledContent(
            "Session",
            value: "rings \(call.rings) · accepts \(call.accepts) · declines \(call.declines) · dismissals \(call.dismissals) · timeouts \(call.timeouts)")
            .textSelection(.enabled)
        LabeledContent(
            "Controls",
            value: "muted \(call.muted ? "yes" : "no") · camera \(call.cameraOn ? "on" : "off") · speaker \(call.speaker ?? "default")")
            .textSelection(.enabled)
    }

    /// Dismissed-but-live calls stay actionable here so dismissing the
    /// banner never strands a ring; live calls get the same actions.
    @ViewBuilder
    private func callEscapeHatch(for c: CallInfo) -> some View {
        let dismissed = call.dismissedIDs.contains(c.id)
        if dismissed {
            LabeledContent("Banner", value: "dismissed (actions below still work)")
                .foregroundStyle(DietColor.textSecondaryColor)
        }
        if c.dir == "in", c.state == "ringing" {
            HStack {
                Button("Accept live") { call.acceptLive() }
                    .disabled(call.busy)
                Button("Accept") { call.accept() }
                    .disabled(call.busy)
                Button("Decline") { call.end() }
                    .disabled(call.busy)
                if dismissed {
                    Button("Recall banner") { call.recall() }
                }
            }
            .buttonStyle(.bordered)
        } else {
            HStack {
                Button("End") { call.end() }
                    .disabled(call.busy)
                if dismissed {
                    Button("Recall banner") { call.recall() }
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
/// totals, breakthrough/suppression counts. The only place these
/// numbers appear — banners never show counts. (Quiet-hours state
/// lives in the Quiet hours section below, not here.)
struct NotificationsDiagRow: View {
    @ObservedObject var unread: UnreadStore
    @ObservedObject var mentions: MentionStore
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
            // om-markunread: totals include horizon overrides (the only
            // place override counts appear — rows badge, never number).
            value: DiagnosticsFormat.unreadLine(
                total: unread.total, chats: unread.chatCount))
            .textSelection(.enabled)
        LabeledContent(
            "Alerts",
            value: DiagnosticsFormat.mentionAlertsLine(
                breakthroughs: breakthroughs, dnd: dnd,
                quiet: quietSuppressions))
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

/// Quiet-hours rows (om-quiet-hours): observes the store so state
/// flips and the suppressed count tick live. The ONLY place the
/// suppressed count appears — Settings and the sidebar never show it.
/// e2-attention appends Focus + active-window rows (never reordered).
struct QuietHoursDiagRow: View {
    @ObservedObject var store: QuietHoursStore
    @ObservedObject var focus: FocusSyncStore
    @ObservedObject var sched: PresenceScheduleStore

    var body: some View {
        LabeledContent(
            "State",
            value: DiagnosticsFormat.quietHoursLine(
                dnd: store.dndActive(), schedule: store.scheduleActive(),
                suppressed: store.suppressedCount,
                focus: focus.quietNow))
            .textSelection(.enabled)
        LabeledContent(
            "Schedule",
            value: scheduleText)
            .textSelection(.enabled)
        LabeledContent("Do Not Disturb", value: store.dndStatus())
            .textSelection(.enabled)
        LabeledContent("Focus", value: focusText)
            .textSelection(.enabled)
        LabeledContent("Active window", value: activeWindowText)
            .textSelection(.enabled)
        LabeledContent(
            "Presence schedule",
            value: sched.enabled
                ? (sched.activeEntry()?.summary() ?? "idle (\(sched.entries.count) entries)")
                : "off")
            .textSelection(.enabled)
        LabeledContent("Last scheduled set", value: lastSetText)
            .textSelection(.enabled)
        if let err = sched.error {
            LabeledContent("Schedule error", value: err)
                .textSelection(.enabled)
        }
    }

    private var lastSetText: String {
        guard let status = sched.lastStatus else { return "never" }
        if let at = sched.lastSetAt {
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.dateFormat = "HH:mm"
            return "\(status.title) at \(fmt.string(from: at))"
        }
        return status.title
    }

    /// Multi-window schedule line: off when nothing is enabled, else
    /// the active window or the idle count.
    private var scheduleText: String {
        let enabled = store.windows.filter(\.enabled)
        if enabled.isEmpty { return "off" }
        if let active = store.activeWindow() { return active.summary() }
        return "idle (\(enabled.count) windows)"
    }

    /// gap-g5: the probe error shows even with sync off — a broken
    /// probe is never hidden behind the toggle.
    private var focusText: String {
        if let error = focus.error { return "unreadable (\(error))" }
        if !focus.syncEnabled { return "sync off" }
        return focus.focusActive ? "active — quiet" : "inactive"
    }

    private var activeWindowText: String {
        store.activeWindow()?.summary() ?? "none"
    }
}

/// Leave/block counters row (om-leave-block): observes both stores
/// so the counts tick as chats leave and users block/unblock. The only
/// place these numbers appear — the sidebar and Settings never show them.
struct LeaveBlockDiagRow: View {
    @ObservedObject var chats: ChatListViewModel
    @ObservedObject var blocked: BlockedStore

    var body: some View {
        LabeledContent(
            "Threads",
            value: DiagnosticsFormat.leaveBlockLine(
                leaves: chats.leavesCompleted, blocks: blocked.count,
                failed: chats.leaveFailures))
            .textSelection(.enabled)
        if let err = chats.leaveError {
            LabeledContent("Last error") {
                Text(err)
                    .font(DietType.caption1)
                    .foregroundStyle(Color(nsColor: DietColor.danger))
                    .textSelection(.enabled)
            }
        }
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
