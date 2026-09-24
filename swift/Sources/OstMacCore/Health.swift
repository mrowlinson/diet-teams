// Health.swift — om-steal-ids lane: per-audience token health + diagnostics UI.
//
// Port of weirdapps teams-access `src/commands/health-check.ts` (MIT):
// one timed read per surface, per-probe status, ok/degraded/broken
// verdict. Adapted to ost's derived-token slots (aad/graph/ic3/recorder/
// skype live in the TOML config, not a multi-audience session file):
// the token layer is offline (status slots), the probe layer is live
// (whoami + teams exercise the Graph token, chats the Skype token).
//
//   let health = HealthStore() // live core fetchers
//   await health.run()         // fills `report` (Settings diagnostics)
// Tests inject mock fetchers (same seam as PresenceStore).
import DietDesign
import Foundation
import SwiftUI

/// Token health + live probes. All fetches run off-main (blocking FFI).
@MainActor
public final class HealthStore: ObservableObject {
    public typealias StatusFetcher = @Sendable () throws -> StatusResponse
    public typealias MeFetcher = @Sendable () throws -> WhoamiResponse
    public typealias TeamsFetcher = @Sendable () throws -> TeamsResponse
    public typealias ChatsFetcher = @Sendable (Int32) throws -> ChatsResponse

    /// Last full report; nil until the first successful status read.
    @Published public private(set) var report: HealthReport?
    /// Status-read failure (probes never fail the run, they fail in place).
    @Published public private(set) var error: String?
    @Published public private(set) var running = false

    private let statusFetcher: StatusFetcher
    private let meFetcher: MeFetcher
    private let teamsFetcher: TeamsFetcher
    private let chatsFetcher: ChatsFetcher

    /// Nonisolated so views can take a default `HealthStore()` in
    /// their (nonisolated) inits; all members stay main-actor-isolated.
    public nonisolated init(
        statusFetcher: @escaping StatusFetcher = { try RustCore.status() },
        meFetcher: @escaping MeFetcher = { try RustCore.whoami() },
        teamsFetcher: @escaping TeamsFetcher = { try RustCore.teams() },
        chatsFetcher: @escaping ChatsFetcher = { try RustCore.chats(limit: $0) }
    ) {
        self.statusFetcher = statusFetcher
        self.meFetcher = meFetcher
        self.teamsFetcher = teamsFetcher
        self.chatsFetcher = chatsFetcher
    }

    /// Offline token slots from a status response (pure, tested).
    public static func tokenSlots(_ st: StatusResponse) -> [HealthToken] {
        [
            HealthToken(audience: "aad", present: st.tokens.aad.present, expired: st.tokens.aad.expired),
            HealthToken(audience: "graph", present: st.tokens.graph.present, expired: st.tokens.graph.expired),
            HealthToken(audience: "ic3", present: st.tokens.ic3.present, expired: st.tokens.ic3.expired),
            HealthToken(audience: "recorder", present: st.tokens.recorder.present, expired: st.tokens.recorder.expired),
            HealthToken(audience: "skype", present: st.tokens.skype.present, expired: st.tokens.skype.expired),
            HealthToken(audience: "refresh", present: st.tokens.refresh_present, expired: false),
        ]
    }

    /// Verdict: upstream probe rule (all ok → ok, none → broken, else
    /// degraded), capped at degraded when any token slot is missing or
    /// expired. Pure, tested.
    public static func verdict(tokens: [HealthToken], probes: [HealthProbe]) -> HealthOverall {
        let okCount = probes.filter(\.ok).count
        let probeVerdict: HealthOverall =
            okCount == probes.count ? .ok : okCount == 0 ? .broken : .degraded
        guard probeVerdict != .broken else { return .broken }
        let tokensBad = tokens.contains { !$0.present || $0.expired }
        return (probeVerdict == .degraded || tokensBad) ? .degraded : .ok
    }

    /// Run the full check: offline slots first, then the three timed
    /// live probes. Probe failures land in the report (never thrown);
    /// only the status read can fail the run.
    public func run() async {
        guard !running else { return }
        running = true
        defer { running = false }
        let statusFn = statusFetcher
        let meFn = meFetcher
        let teamsFn = teamsFetcher
        let chatsFn = chatsFetcher
        let st: StatusResponse
        do {
            st = try await Task.detached { try statusFn() }.value
        } catch {
            self.error = String(describing: error)
            return
        }
        let tokens = Self.tokenSlots(st)
        var probes: [HealthProbe] = []
        var account: String?
        // Probe 1: Graph /me (whoami exercises the Graph token).
        do {
            let t0 = Date()
            do {
                let me = try await Task.detached { try meFn() }.value
                account = me.mail
                probes.append(HealthProbe(
                    name: "graph_me", ok: true,
                    detail: "mail=\(me.mail ?? "(none)")",
                    durationMs: Self.ms(since: t0)))
            } catch {
                probes.append(HealthProbe(
                    name: "graph_me", ok: false,
                    detail: Self.message(for: error).prefix(200).description,
                    durationMs: Self.ms(since: t0)))
            }
        }
        // Probe 2: Graph /me/joinedTeams.
        do {
            let t0 = Date()
            do {
                let teams = try await Task.detached { try teamsFn() }.value
                probes.append(HealthProbe(
                    name: "graph_joined_teams", ok: true,
                    detail: "count=\(teams.teams.count)",
                    durationMs: Self.ms(since: t0)))
            } catch {
                probes.append(HealthProbe(
                    name: "graph_joined_teams", ok: false,
                    detail: Self.message(for: error).prefix(200).description,
                    durationMs: Self.ms(since: t0)))
            }
        }
        // Probe 3: chat list (exercises the Skype token path).
        do {
            let t0 = Date()
            do {
                let chats = try await Task.detached { try chatsFn(1) }.value
                probes.append(HealthProbe(
                    name: "chatsvc_list", ok: true,
                    detail: "chats=\(chats.chats.count)",
                    durationMs: Self.ms(since: t0)))
            } catch {
                probes.append(HealthProbe(
                    name: "chatsvc_list", ok: false,
                    detail: Self.message(for: error).prefix(200).description,
                    durationMs: Self.ms(since: t0)))
            }
        }
        report = HealthReport(
            overall: Self.verdict(tokens: tokens, probes: probes),
            tokens: tokens, probes: probes, accountUPN: account)
        error = nil
    }

    /// Fire-and-forget run (Settings diagnostics, refresh button).
    public func runSoon() {
        Task { await run() }
    }

    /// Adopt a report without core (tests, previews, fixed Settings).
    public func adopt(_ report: HealthReport) {
        self.report = report
        error = nil
    }

    /// Drop everything after sign-out (fail closed).
    public func clear() {
        report = nil
        error = nil
    }

    private static func ms(since t0: Date) -> Int {
        Int(Date().timeIntervalSince(t0) * 1000)
    }

    /// Unwrap core envelope failures (same rule as AuthViewModel).
    static func message(for error: Error) -> String {
        if case CoreCallError.failed(let m) = error { return m }
        return String(describing: error)
    }

    /// Canned report for previews and fixed views. Never core.
    public static var demo: HealthReport {
        HealthReport(
            overall: .degraded,
            tokens: [
                HealthToken(audience: "aad", present: true, expired: false),
                HealthToken(audience: "graph", present: true, expired: false),
                HealthToken(audience: "ic3", present: true, expired: true),
                HealthToken(audience: "recorder", present: false, expired: false),
                HealthToken(audience: "skype", present: true, expired: false),
                HealthToken(audience: "refresh", present: true, expired: false),
            ],
            probes: [
                HealthProbe(name: "graph_me", ok: true, detail: "mail=demo@example.com", durationMs: 120),
                HealthProbe(name: "graph_joined_teams", ok: true, detail: "count=2", durationMs: 210),
                HealthProbe(name: "chatsvc_list", ok: false, detail: "demo offline", durationMs: 0),
            ],
            accountUPN: "demo@example.com")
    }
}

/// Diagnostics panel: overall badge, per-audience token slots, timed
/// probe rows. Used by Settings; previews pass a demo-adopted store.
public struct HealthView: View {
    @ObservedObject private var store: HealthStore

    public init(store: HealthStore) {
        self.store = store
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                overallBadge
                Spacer()
                Button("Run check") { store.runSoon() }
                    .disabled(store.running)
            }
            if let err = store.error {
                Text(err).font(DietType.caption1)
                    .foregroundStyle(Color(nsColor: DietColor.danger))
                    .textSelection(.enabled)
            }
            if let report = store.report {
                if let upn = report.accountUPN {
                    LabeledContent("Account", value: upn)
                        .font(DietType.caption1)
                }
                tokenSection(report.tokens)
                probeSection(report.probes)
            } else if store.error == nil {
                Text(store.running ? "Checking…" : "Not checked yet")
                    .font(DietType.caption1).foregroundStyle(DietColor.textSecondaryColor)
            }
        }
    }

    private var overallBadge: some View {
        let overall = store.report?.overall
        let label: String = switch overall {
        case .ok: "Healthy"
        case .degraded: "Degraded"
        case .broken: "Broken"
        case nil: store.running ? "Checking…" : "Unknown"
        }
        let color: Color = switch overall {
        case .ok: Color(nsColor: DietColor.success)
        case .degraded: Color(nsColor: DietColor.warning)
        case .broken: Color(nsColor: DietColor.danger)
        case nil: DietColor.textTertiaryColor
        }
        return HStack(spacing: DietSpace.xs) {
            Circle().fill(color).frame(
                width: DietSize.presenceDot, height: DietSize.presenceDot)
            Text(label).font(DietType.headline)
        }
    }

    private func tokenSection(_ tokens: [HealthToken]) -> some View {
        VStack(alignment: .leading, spacing: DietSpace.xxs) {
            Text("Tokens").font(DietType.caption1).bold()
            ForEach(tokens, id: \.audience) { t in
                HStack {
                    Circle().fill(tokenColor(t)).frame(
                        width: DietSize.presenceDot,
                        height: DietSize.presenceDot)
                    Text(t.audience).font(DietType.caption1).monospaced()
                    Spacer()
                    Text(t.state).font(DietType.caption1)
                        .foregroundStyle(DietColor.textSecondaryColor)
                }
            }
        }
    }

    private func tokenColor(_ t: HealthToken) -> Color {
        !t.present
            ? DietColor.textTertiaryColor
            : t.expired
                ? Color(nsColor: DietColor.danger)
                : Color(nsColor: DietColor.success)
    }

    private func probeSection(_ probes: [HealthProbe]) -> some View {
        VStack(alignment: .leading, spacing: DietSpace.xs) {
            Text("Probes").font(DietType.caption1).bold()
            ForEach(probes, id: \.name) { p in
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Image(systemName: p.ok ? "checkmark.circle" : "xmark.circle")
                            .foregroundStyle(p.ok
                                ? Color(nsColor: DietColor.success)
                                : Color(nsColor: DietColor.danger))
                        Text(p.name).font(DietType.caption1).monospaced()
                        Spacer()
                        Text("\(p.durationMs)ms")
                            .font(DietType.captionMono)
                            .foregroundStyle(DietColor.textSecondaryColor)
                    }
                    Text(p.detail)
                        .font(DietType.caption2)
                        .foregroundStyle(DietColor.textSecondaryColor)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                .help(p.detail)
            }
        }
    }
}
