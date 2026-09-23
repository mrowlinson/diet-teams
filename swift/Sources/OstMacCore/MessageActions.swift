// MessageActions.swift — om-msgactions lane: copy/forward/save helpers.
//
// Pure logic behind the bubble context menu (top-level items only, never
// a submenu). The views in ConversationView.swift own the pasteboard /
// sheet / save-panel calls; everything testable lives here plus
// ConversationStore.forward(_:toChatID:) (demo-recorded, live via send).
import Foundation

/// Copy/forward/save text + filename builders. No view or FFI code.
public enum MessageActions {
    /// What Copy puts on the pasteboard: exactly what the bubble shows
    /// (shortcodes expanded, same source as MessageRender.attributedBody).
    public static func copyText(for message: ChatMessage) -> String {
        MessageRender.renderText(for: message)
    }

    /// What Forward sends to the picked chat: the plain bubble text, no
    /// attribution prefix (the destination bubble already stamps its own
    /// sender/time; a prefix would double-attribute on every hop).
    public static func forwardBody(for message: ChatMessage) -> String {
        copyText(for: message)
    }

    /// What Save writes to disk: a stable header (sender + raw ISO
    /// timestamp, never the relative displayTime) plus the bubble text.
    /// Image-only bubbles still save their header (text may be empty).
    public static func saveBody(for message: ChatMessage) -> String {
        "From: \(message.sender)\nDate: \(message.timestamp)\n\n\(copyText(for: message))\n"
    }

    /// Default save-panel filename: `message-<sanitized id>.txt`.
    /// Falls back to `message.txt` when the id sanitizes to nothing.
    public static func saveFilename(for message: ChatMessage) -> String {
        let base = sanitizedFilename("message-\(message.id)")
        let stem = base.isEmpty ? "message" : base
        return "\(stem).txt"
    }

    /// Filename-safe: runs of anything outside [A-Za-z0-9._-] become one
    /// `-`, leading/trailing dots + dashes trimmed, stem capped at 60
    /// chars (extension added by the caller).
    public static func sanitizedFilename(_ raw: String) -> String {
        var out = ""
        out.reserveCapacity(raw.count)
        var dash = false
        for ch in raw {
            let ok = ch.isLetter || ch.isNumber || ch == "." || ch == "_" || ch == "-"
            if ok {
                out.append(ch)
                dash = false
            } else if !dash {
                out.append("-")
                dash = true
            }
        }
        while out.hasPrefix(".") || out.hasPrefix("-") { out.removeFirst() }
        while out.hasSuffix(".") || out.hasSuffix("-") { out.removeLast() }
        if out.count > 60 { out = String(out.prefix(60)) }
        while out.hasSuffix(".") || out.hasSuffix("-") { out.removeLast() }
        return out
    }

    /// One forwarded bubble (om-msgactions): source id + destination +
    /// sent body. Host-side only (never decoded from core).
    public struct ForwardRecord: Equatable, Sendable {
        public let messageID: String
        public let destChatID: String
        public let body: String

        public init(messageID: String, destChatID: String, body: String) {
            self.messageID = messageID
            self.destChatID = destChatID
            self.body = body
        }
    }

    /// One-line quote for the forward sheet header: sender + collapsed
    /// preview (120 chars + ellipsis, same shape as reply quotes).
    public static func forwardPreview(for message: ChatMessage) -> String {
        let flat = copyText(for: message)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flat.count > 120 else { return flat.isEmpty ? "(no text)" : flat }
        return String(flat.prefix(120)) + "…"
    }
}
