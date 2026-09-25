// TestCallSettings.swift — om-testcall-settings lane: Settings "Calls"
// section state.
//
// Pure mapping (signedIn/busy/slot -> button + status) so the section
// stays a dumb native render. The place path reuses the echo-test-call
// machinery end to end: CallStore.echoLive -> RustCore.callEchoLive ->
// core ostmac_call_echo_live (echo bot + live mic/speaker media, user
// hears their own audio back). No human targets ever: the echo bot is
// the only callee on this path.
import Foundation

/// Settings test-call row state (all copy lives here, tested).
public struct TestCallUiState: Equatable, Sendable {
    public let placeLabel: String
    public let placeEnabled: Bool
    public let showEnd: Bool
    public let endEnabled: Bool
    public let status: String

    public init(
        placeLabel: String, placeEnabled: Bool, showEnd: Bool,
        endEnabled: Bool, status: String
    ) {
        self.placeLabel = placeLabel
        self.placeEnabled = placeEnabled
        self.showEnd = showEnd
        self.endEnabled = endEnabled
        self.status = status
    }
}

public enum TestCallSettings {
    /// Peer name the core stamps on echo-bot legs (calls.rs place_inner).
    public static let echoPeerName = "Echo (Test Call)"

    public static func describe(
        signedIn: Bool, busy: Bool, call: CallInfo?
    ) -> TestCallUiState {
        if let c = call, c.isActive {
            let echo = c.peerName == echoPeerName
            let status: String
            switch c.state {
            case "connected" where echo:
                status = c.liveMedia == true
                    ? "Test call connected — speak; you hear your own audio back."
                    : "Test call connected (signaling only — no audio)."
            case "connected":
                status = "Call connected (\(c.displayPeer))."
            case "ringing":
                status = "Ringing (\(c.displayPeer))…"
            default:
                status = echo
                    ? "Placing test call…" : "Placing call (\(c.displayPeer))…"
            }
            return TestCallUiState(
                placeLabel: "Place test call", placeEnabled: false,
                showEnd: true, endEnabled: !busy, status: status)
        }
        if !signedIn {
            return TestCallUiState(
                placeLabel: "Place test call", placeEnabled: false,
                showEnd: false, endEnabled: false,
                status: "Sign in to place a test call.")
        }
        if busy {
            return TestCallUiState(
                placeLabel: "Place test call", placeEnabled: false,
                showEnd: false, endEnabled: false,
                status: "Placing test call…")
        }
        return TestCallUiState(
            placeLabel: "Place test call", placeEnabled: true,
            showEnd: false, endEnabled: false,
            status: "Call the echo bot to verify your mic and speaker. No one else is called.")
    }
}
