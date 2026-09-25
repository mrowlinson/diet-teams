// Accessibility.swift — om-a2-labels: VoiceOver label helpers +
// visible focus ring for plain icon buttons.
//
// Labels live here (not inline) so the dynamic strings have a pure,
// tested seam (A11yLabelsTests); static one-word labels stay inline
// at the control (existing "Send failed" / "Meeting live" pattern).
import DietDesign
import SwiftUI

/// Dynamic VoiceOver labels shared by chat + meeting surfaces.
public enum A11yLabels {
    /// Jump pill: "3 new messages. Jump to latest." The titled pill
    /// names the wait; the plain jump states the action.
    public static func jumpPill(title: String?) -> String {
        guard let title, !title.isEmpty else {
            return "Jump to latest messages"
        }
        return "\(title). Jump to latest."
    }

    /// Reminder complete toggle: names the task + its state.
    public static func reminderComplete(title: String, completed: Bool) -> String {
        completed ? "Completed: \(title)" : "Mark done: \(title)"
    }
}

/// Visible keyboard-focus ring for `.plain` icon buttons. The plain
/// style strips the bezel that carries the system ring, so focus
/// would be invisible; this overlays a 2pt accent outline (same
/// weight as the system ring) only while focused.
public struct PlainFocusRing: ViewModifier {
    @FocusState private var focused: Bool
    private let radius: CGFloat

    public init(radius: CGFloat = DietRadius.control) {
        self.radius = radius
    }

    public func body(content: Content) -> some View {
        content
            .focused($focused)
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .stroke(
                        focused ? Color.accentColor : .clear,
                        lineWidth: 2)
            )
    }
}

public extension View {
    /// 2pt accent focus outline while keyboard-focused (plain buttons).
    public func plainFocusRing(radius: CGFloat = DietRadius.control) -> some View {
        modifier(PlainFocusRing(radius: radius))
    }
}
