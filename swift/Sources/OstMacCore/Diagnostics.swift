// Diagnostics.swift — om-statusbar lane: pure one-line formatters for the
// counters that moved out of the status bar into the Diagnostics window
// (Window ▸ Diagnostics). The slim status bar (Live dot + errors) and the
// Diagnostics window share these so the tooltip and the rows never drift.
// Tested (DiagnosticsTests); views stay dumb.
import Foundation

public enum DiagnosticsFormat {
    /// `core 1.2.3 · init=0` (was the status bar's leading counter).
    public static func coreLine(version: String, initCode: Int32) -> String {
        "core \(version) · init=\(initCode)"
    }

    /// Session one-liner: demo mode, signed in/out, or still checking.
    public static func sessionLine(isDemo: Bool, signedIn: Bool?) -> String {
        if isDemo { return "DEMO · offline" }
        return switch signedIn {
        case .some(true): "signed in"
        case .some(false): "signed out"
        case .none: "auth ?"
        }
    }

    /// Full feed line with counters (was the status bar's feed text).
    public static func feedLine(
        state: RealtimeFeed.State, events: Int, polls: Int, resyncs: Int
    ) -> String {
        switch state {
        case .live:
            "Live · \(events) new · \(polls) polls · \(resyncs) resyncs"
        case .retryWait:
            "Connecting… (\(events) new · \(resyncs) resyncs)"
        case .stopped:
            "Realtime off"
        }
    }

    /// Short feed state word for the status-bar dot tooltip prefix.
    public static func feedWord(state: RealtimeFeed.State) -> String {
        switch state {
        case .live: "Live"
        case .retryWait: "Connecting…"
        case .stopped: "Realtime off"
        }
    }

    /// Typing counters (om-typing): session events + live indicators.
    /// Diagnostics window only — typing never shows a count elsewhere.
    public static func typingLine(events: Int, active: Int) -> String {
        "\(events) events · \(active) active"
    }

    /// Read-receipt counters (om-receipts): sent positions, tracked
    /// threads, peer positions. Timeline shows Seen with no numbers;
    /// the counts live here only.
    public static func receiptsLine(sent: Int, threads: Int, peers: Int) -> String {
        "\(sent) sent · \(threads) threads · \(peers) peers"
    }

    /// Recent-call counters (om-call-history): entries + missed. The
    /// list lives in the Recent Calls window; counts live here only.
    public static func callsLine(total: Int, missed: Int) -> String {
        "\(total) recent · \(missed) missed"
    }
}
