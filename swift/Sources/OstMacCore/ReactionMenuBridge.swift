// ReactionMenuBridge.swift — om-reactions/om-msgactions/om-replies/om-editdel:
// the bubble's ONE right-click menu (inline emoji row + Reply / Copy /
// Forward / Save, plus Edit / Delete on own bubbles — all top-level,
// no submenu).
//
// Why AppKit: SwiftUI renders ControlGroup-in-menu as a submenu with an
// inline preview (verified by screenshot: the row carries a ">" that
// opens a vertical submenu). The merge gate needs reacts directly in
// the menu, so the row is an NSMenuItem custom view (NSStackView of
// NSButtons), which never shows a submenu indicator. Reply/Copy/
// Forward/Save ride the same NSMenu as plain top-level items.
//
// Delivery: an NSEvent local monitor (not a covering overlay, so links
// and badge taps are untouched). Right-clicks landing in the bubble's
// bounds pop the custom menu and are swallowed; every other event
// passes through. The hit rect inflates upward only on reacted bubbles
// so the overlapping tapback badges right-click onto the same menu.
import AppKit
import SwiftUI

/// Bubble-attached right-click menu. Installed as the bubble's
/// `.background` (sized to the bubble, never covering content).
struct ReactionMenuBridge: NSViewRepresentable {
    let message: ChatMessage
    let onReact: (String) -> Void
    var failed: Bool = false
    var onCopy: () -> Void = {}
    var onForward: () -> Void = {}
    var onSave: () -> Void = {}
    var onRetry: () -> Void = {}
    var onReply: () -> Void = {}
    var onEdit: () -> Void = {}
    var onDelete: () -> Void = {}

    func makeNSView(context: Context) -> ReactionMenuAnchorView {
        let view = ReactionMenuAnchorView()
        view.message = message
        view.onReact = onReact
        view.failed = failed
        view.onCopy = onCopy
        view.onForward = onForward
        view.onSave = onSave
        view.onRetry = onRetry
        view.onReply = onReply
        view.onEdit = onEdit
        view.onDelete = onDelete
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(
            matching: .rightMouseDown
        ) { [weak view] event in
            guard let view, view.window != nil,
                  event.window == view.window,
                  view.claims(event) else { return event }
            view.popMenu(with: event)
            return nil
        }
        return view
    }

    func updateNSView(_ view: ReactionMenuAnchorView, context _: Context) {
        view.message = message
        view.onReact = onReact
        view.failed = failed
        view.onCopy = onCopy
        view.onForward = onForward
        view.onSave = onSave
        view.onRetry = onRetry
        view.onReply = onReply
        view.onEdit = onEdit
        view.onDelete = onDelete
    }

    func dismantleNSView(_: ReactionMenuAnchorView, coordinator: Coordinator) {
        if let m = coordinator.monitor {
            NSEvent.removeMonitor(m)
            coordinator.monitor = nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var monitor: Any?
    }
}

/// Zero-draw anchor sized to the bubble by `.background`.
/// Hit rect = bounds, inflated upward past the tapback-badge overhang
/// only when the bubble carries reactions.
final class ReactionMenuAnchorView: NSView {
    var message: ChatMessage = ChatMessage(id: "", sender: "", timestamp: "", content: "")
    var onReact: (String) -> Void = { _ in }
    var failed: Bool = false
    var onCopy: () -> Void = {}
    var onForward: () -> Void = {}
    var onSave: () -> Void = {}
    var onRetry: () -> Void = {}
    var onReply: () -> Void = {}
    var onEdit: () -> Void = {}
    var onDelete: () -> Void = {}

    /// Upward overhang of the tapback badges (matches the ZStack offset).
    static let badgeOverhang: CGFloat = 20

    override init(frame: NSRect) {
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func claims(_ event: NSEvent) -> Bool {
        var rect = bounds
        if !message.reactions.isEmpty {
            // AppKit y=0 is the bottom edge: the badges overhang the
            // TOP, so only the height grows.
            rect.size.height += Self.badgeOverhang
        }
        let at = convert(event.locationInWindow, from: nil)
        return rect.contains(at)
    }

    func popMenu(with event: NSEvent) {
        let menu = NSMenu()
        let row = NSMenuItem()
        row.view = ReactionMenuRowView(
            emojis: ConversationStore.reactionEmojis,
            menu: menu,
            helpFor: { [message] in MessageBubble.reactHelp(emoji: $0, on: message) },
            onReact: onReact)
        menu.addItem(row)
        menu.addItem(.separator())
        // TOP-LEVEL ONLY: every action is a direct item, never a submenu.
        let reply = NSMenuItem(
            title: "Reply", action: #selector(replyAction), keyEquivalent: "")
        reply.target = self
        menu.addItem(reply)
        let copy = NSMenuItem(
            title: "Copy", action: #selector(copyAction), keyEquivalent: "c")
        copy.target = self
        menu.addItem(copy)
        let forward = NSMenuItem(
            title: "Forward…", action: #selector(forwardAction), keyEquivalent: "")
        forward.target = self
        menu.addItem(forward)
        let save = NSMenuItem(
            title: "Save…", action: #selector(saveAction), keyEquivalent: "")
        save.target = self
        menu.addItem(save)
        if message.isOwn {
            let edit = NSMenuItem(
                title: "Edit…", action: #selector(editAction), keyEquivalent: "")
            edit.target = self
            menu.addItem(edit)
            let delete = NSMenuItem(
                title: "Delete…", action: #selector(deleteAction), keyEquivalent: "")
            delete.target = self
            menu.addItem(delete)
        }
        if failed {
            let retry = NSMenuItem(
                title: "Retry send", action: #selector(retryAction), keyEquivalent: "")
            retry.target = self
            menu.addItem(retry)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func copyAction() {
        onCopy()
    }

    @objc private func forwardAction() {
        onForward()
    }

    @objc private func saveAction() {
        onSave()
    }

    @objc private func retryAction() {
        onRetry()
    }

    @objc private func replyAction() {
        onReply()
    }

    @objc private func editAction() {
        onEdit()
    }

    @objc private func deleteAction() {
        onDelete()
    }
}

/// One press target per emoji button (NSButton needs target/action).
private final class ReactionMenuButtonTarget: NSObject {
    let emoji: String
    let menu: NSMenu
    let onReact: (String) -> Void

    init(emoji: String, menu: NSMenu, onReact: @escaping (String) -> Void) {
        self.emoji = emoji
        self.menu = menu
        self.onReact = onReact
    }

    /// Custom-view buttons do not dismiss the menu themselves.
    @objc func press() {
        menu.cancelTracking()
        onReact(emoji)
    }
}

/// Horizontal emoji row for the menu item's custom view.
private final class ReactionMenuRowView: NSStackView {
    private var targets: [ReactionMenuButtonTarget] = []

    init(
        emojis: [String], menu: NSMenu,
        helpFor: @escaping (String) -> String,
        onReact: @escaping (String) -> Void
    ) {
        super.init(frame: NSRect(x: 0, y: 0, width: 208, height: 30))
        orientation = .horizontal
        alignment = .centerY
        distribution = .fill
        spacing = 2
        edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 8)
        for emoji in emojis {
            let target = ReactionMenuButtonTarget(
                emoji: emoji, menu: menu, onReact: onReact)
            targets.append(target)
            let button = NSButton(title: emoji, target: target, action: #selector(ReactionMenuButtonTarget.press))
            button.bezelStyle = .inline
            button.setButtonType(.momentaryPushIn)
            button.font = .systemFont(ofSize: 15)
            button.toolTip = helpFor(emoji)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 28).isActive = true
            button.heightAnchor.constraint(equalToConstant: 26).isActive = true
            addArrangedSubview(button)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
