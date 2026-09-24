// DietBubble.swift — message bubbles. Incoming left/well,
// outgoing right/accent-tint; failed shows red tail + retry.
import SwiftUI

public enum DietBubbleDirection {
    case incoming, outgoing
}

/// Failed-send marker: red icon OUTSIDE the bubble, retry via the
/// bubble's context menu. Shared by DietBubble (Showcase, Meeting)
/// and the timeline MessageBubble — one failed language everywhere.
public struct DietBubbleFailedIcon: View {
    public init() {}

    public var body: some View {
        Image(systemName: "exclamationmark.circle.fill")
            .font(.system(size: DietSize.iconMD))
            .foregroundStyle(Color(nsColor: DietColor.danger))
            .accessibilityLabel("Send failed")
    }
}

public struct DietBubble: View {
    private let text: String
    private let direction: DietBubbleDirection
    private let failed: Bool
    private let onRetry: (() -> Void)?

    public init(
        _ text: String,
        direction: DietBubbleDirection,
        failed: Bool = false,
        onRetry: (() -> Void)? = nil
    ) {
        self.text = text
        self.direction = direction
        self.failed = failed
        self.onRetry = onRetry
    }

    public var body: some View {
        HStack(spacing: DietSpace.xs) {
            if direction == .outgoing { Spacer(minLength: DietSpace.xl) }
            if failed { DietBubbleFailedIcon() }
            Text(text)
                .font(DietType.body)
                .foregroundStyle(DietColor.textPrimaryColor)
                .padding(.horizontal, DietSpace.sm + DietSpace.xs)
                .padding(.vertical, DietSpace.xs)
                .background(
                    direction == .outgoing
                        ? DietColor.bubbleOutColor : DietColor.bubbleInColor,
                    in: RoundedRectangle(
                        cornerRadius: DietRadius.bubble))
                .overlay(
                    failed ? RoundedRectangle(
                        cornerRadius: DietRadius.bubble
                    ).stroke(
                        Color(nsColor: DietColor.danger), lineWidth: 1
                    ) : nil)
            if direction == .incoming { Spacer(minLength: DietSpace.xl) }
        }
        .contextMenu {
            if failed, let onRetry {
                Button("Retry send", systemImage: "arrow.clockwise") {
                    onRetry()
                }
            }
        }
    }
}

/// Day separator row: hairline — LABEL — hairline.
public struct DietDaySeparator: View {
    private let label: String

    public init(_ label: String) {
        self.label = label
    }

    public var body: some View {
        HStack(spacing: DietSpace.sm) {
            DietDividerH()
            Text(label)
                .font(DietType.caption1)
                .foregroundStyle(DietColor.textTertiaryColor)
            DietDividerH()
        }
        .padding(.vertical, DietSpace.xs)
    }
}
