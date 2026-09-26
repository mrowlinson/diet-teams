// MeetingsBrowser.swift — SwiftUI browser: upcoming meetings + join box.
import DietDesign
import OstMacCore
import SwiftUI

/// Meetings browser. Join-by-link field on top, upcoming meetings below;
/// thread joins open the pre-join sheet (mic/camera preview + toggles),
/// the lobby banner tracks waiting-room state. Mirrors TeamsBrowser
/// states; errors are `DietEmptyState` / `DietBanner`.
public struct MeetingsBrowser: View {
    @ObservedObject private var model: MeetingsViewModel
    /// Pop-out tap (gap-g8): row menu "Pop Out" + double-click route
    /// here (the host owns openWindow). Nil = no pop-out UI.
    private let onPopOut: ((MeetingItem) -> Void)?
    /// Reduce Motion (om-a1-motion): state changes land instantly.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(model: MeetingsViewModel, onPopOut: ((MeetingItem) -> Void)? = nil) {
        self.model = model
        self.onPopOut = onPopOut
    }

    public var body: some View {
        VStack(spacing: 0) {
            joinField
            DietSeamH()
            if let banner = model.lobbyBanner {
                lobbyBanner(banner)
                DietSeamH()
            }
            Group {
                switch model.state {
                case .loading:
                    VStack(spacing: DietSpace.sm) {
                        ProgressView()
                        Text("Loading meetings…")
                            .font(DietType.callout)
                            .foregroundStyle(DietColor.textSecondaryColor)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
                case .empty:
                    DietEmptyState(
                        systemImage: "calendar",
                        title: "No upcoming meetings",
                        message: "Meetings with Teams links in the next 7 days will appear here.")
                        .transition(.opacity)
                case .error(let message):
                    DietEmptyState(
                        systemImage: "exclamationmark.triangle",
                        title: "Couldn't load meetings",
                        message: message,
                        actionLabel: "Retry",
                        action: { model.refresh() })
                        .transition(.opacity)
                case .loaded:
                    meetingList
                        .transition(.opacity)
                }
            }
            .animation(DietMotion.gated(reduceMotion: reduceMotion), value: model.state)
        }
        .sheet(isPresented: $model.showPreJoin) {
            if let target = model.pendingJoin {
                PreJoinSheet(
                    target: target,
                    onJoin: { mic, cam in model.confirmJoin(micOn: mic, cameraOn: cam) },
                    onCancel: { model.cancelPreJoin() })
            }
        }
    }

    private var joinField: some View {
        VStack(alignment: .leading, spacing: DietSpace.xs) {
            HStack(spacing: DietSpace.sm) {
                TextField("Paste a meeting link", text: $model.joinText)
                    .textFieldStyle(.roundedBorder)
                    .font(DietType.callout)
                    .onSubmit { model.submitJoin() }
                    .disabled(model.parsing)
                    .accessibilityLabel("Meeting link")
                if model.parsing {
                    ProgressView().controlSize(.small)
                } else {
                    Button(model.joinLabel) { model.submitJoin() }
                        .buttonStyle(.bordered)
                        .disabled(
                            model.joinText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help("Parse the link, then join or open it")
                }
            }
            if let hint = model.joinHint, model.target != nil {
                Text(hint)
                    .font(DietType.caption1)
                    .foregroundStyle(DietColor.textSecondaryColor)
            }
        }
        .padding(.horizontal, DietSpace.sm)
        .padding(.vertical, DietSpace.sm)
    }

    private func lobbyBanner(_ text: String) -> some View {
        HStack(spacing: DietSpace.sm) {
            if model.lobby == .joining || model.lobby == .lobby {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: model.lobby == .failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(Color(
                        nsColor: model.lobby == .failed ? DietColor.danger : DietColor.success))
            }
            Text(text)
                .font(DietType.callout)
                .foregroundStyle(DietColor.textPrimaryColor)
                .lineLimit(2)
            Spacer()
            if model.lobby == .failed || model.lobby == .admitted {
                Button("Dismiss") { model.dismissLobby() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, DietSpace.sm)
        .padding(.vertical, DietSpace.sm)
        .background(Color(nsColor: DietColor.warning).opacity(0.12))
        .accessibilityLabel("Join status: \(text)")
    }

    private var meetingList: some View {
        List(model.meetings) { meeting in
            meetingRow(meeting)
        }
        .listStyle(.plain)
    }

    private func meetingRow(_ meeting: MeetingItem) -> some View {
        HStack(spacing: DietSpace.sm) {
                VStack(alignment: .leading, spacing: DietSpace.xxs) {
                    Text(meeting.subject)
                        .font(DietType.callout).bold()
                        .foregroundStyle(DietColor.textPrimaryColor)
                        .lineLimit(2)
                    HStack(spacing: DietSpace.xs) {
                        if let when = meeting.displayStart {
                            Text(when)
                                .font(DietType.caption1)
                                .foregroundStyle(DietColor.textSecondaryColor)
                        }
                        if let org = meeting.organizer {
                            Text(org)
                                .font(DietType.caption1)
                                .foregroundStyle(DietColor.textSecondaryColor)
                                .lineLimit(1)
                        }
                    }
                }
                Spacer()
                if meeting.isJoinable {
                    Button("Join") { model.joinMeeting(meeting) }
                        .buttonStyle(.bordered)
                        .help("Join \(meeting.subject)")
                } else {
                    Text("No link")
                        .font(DietType.caption1)
                        .foregroundStyle(DietColor.textSecondaryColor)
                }
            }
            .padding(.vertical, DietSpace.xxs)
            // Double-click pops the meeting out (gap-g8, chats
            // precedent); simultaneous so Join still lands.
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                onPopOut?(meeting)
            })
            .contextMenu {
                if let onPopOut {
                    Button("Pop Out", systemImage: "arrow.up.right.square") {
                        onPopOut(meeting)
                    }
                }
            }
    }
}

/// Pre-join device check: camera preview + mic meter with on/off
/// toggles. Join dials signaling only — the caption says so.
public struct PreJoinSheet: View {
    private let target: JoinTarget
    private let onJoin: (Bool, Bool) -> Void
    private let onCancel: () -> Void
    @StateObject private var prejoin = PreJoinModel()

    public init(target: JoinTarget, onJoin: @escaping (Bool, Bool) -> Void, onCancel: @escaping () -> Void) {
        self.target = target
        self.onJoin = onJoin
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DietSpace.sm) {
            Text("Join meeting")
                .font(DietType.title3).bold()
                .foregroundStyle(DietColor.textPrimaryColor)
            if prejoin.cameraOn, prejoin.camera.running {
                CameraPreviewView(session: prejoin.camera.session)
                    .frame(width: 320, height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: DietRadius.control))
                    .overlay(RoundedRectangle(cornerRadius: DietRadius.control)
                        .stroke(DietColor.dividerColor))
            } else {
                RoundedRectangle(cornerRadius: DietRadius.control)
                    .fill(DietColor.wellColor)
                    .frame(width: 320, height: 200)
                    .overlay {
                        VStack(spacing: DietSpace.xs) {
                            Image(systemName: "video.slash")
                                .font(.system(size: DietSize.iconLG))
                                .foregroundStyle(DietColor.textSecondaryColor)
                            Text("Camera off")
                                .font(DietType.callout)
                                .foregroundStyle(DietColor.textSecondaryColor)
                        }
                    }
            }
            Toggle("Microphone", isOn: $prejoin.micOn)
                .font(DietType.callout)
                .toggleStyle(.switch)
            LevelBar(fraction: prejoin.level, live: prejoin.levelLive && prejoin.micOn)
                .frame(width: 320)
                .accessibilityLabel("Microphone level")
            if prejoin.micDenied {
                Text("Microphone denied — allow Better Teams in System Settings › Privacy & Security › Microphone")
                    .font(DietType.caption1)
                    .foregroundStyle(Color(nsColor: DietColor.warning))
            }
            Toggle("Camera", isOn: $prejoin.cameraOn)
                .font(DietType.callout)
                .toggleStyle(.switch)
            Text("Signaling only — mic/camera apply when live media attaches.")
                .font(DietType.caption1)
                .foregroundStyle(DietColor.textSecondaryColor)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                Button("Join now") { onJoin(prejoin.micOn, prejoin.cameraOn) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .help(joinHelp)
            }
        }
        .padding(DietSpace.edge)
        .frame(width: 368)
        .onAppear { prejoin.start() }
        .onDisappear { prejoin.stop() }
    }

    private var joinHelp: String {
        if let tid = target.threadID { return "Dial \(tid) (signaling)" }
        return "Dial this meeting (signaling)"
    }
}
