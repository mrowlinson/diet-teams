// ReactionMenuBridge.swift — om-reactions/om-msgactions/om-replies/om-editdel/om-react-polish/om-pinmessages:
// the bubble's ONE right-click menu (inline emoji row + Reply / Copy /
// Forward / Save / Pin-Unpin, plus Edit / Delete on own bubbles — all
// top-level, no submenu).
//
// Why AppKit: SwiftUI renders ControlGroup-in-menu as a submenu with an
// inline preview (verified by screenshot: the row carries a ">" that
// opens a vertical submenu). The merge gate needs reacts directly in
// the menu, so the row is an NSMenuItem custom view (NSStackView of
// NSButtons), which never shows a submenu indicator. Reply/Copy/
// Forward/Save ride the same NSMenu as plain top-level items.
//
// Row polish (om-react-polish): bare emoji buttons (borderless, no focus
// halo — the .inline bezel drew grey circles) with a trailing ＋ that
// opens the more-picker popover (search + recents + categories).
// `allowsContextMenuPlugIns` stays off so the system never injects an
// "Ask Siri" item above the row.
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
    /// Pinned state (om-pinmessages): drives the Pin/Unpin label.
    var isPinned: Bool = false
    var onTogglePin: () -> Void = {}

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
        view.isPinned = isPinned
        view.onTogglePin = onTogglePin
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
        view.isPinned = isPinned
        view.onTogglePin = onTogglePin
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
    var isPinned: Bool = false
    var onTogglePin: () -> Void = {}

    /// Upward overhang of the tapback badges (badge half-height ~10 +
    /// the ZStack's 16pt lift, plus 2pt breathing room). Shared by the
    /// menu hit rect and the bubble's top clearance padding.
    static let badgeOverhang: CGFloat = 28

    /// Shot-hook note (--show-picker): object = target message id.
    /// Only the matching bubble's anchor opens its picker.
    static let shotPickerNote = Notification.Name("om.shot.showPicker")
    /// Keyboard path (om-a3-keyboard): the focused bubble's React item
    /// posts this (object = message id); the matching anchor opens its
    /// picker directly — no retry, keyboard use means frontmost app.
    static let keyboardPickerNote = Notification.Name("om.bubble.showPicker")
    private var shotObserver: NSObjectProtocol?
    private var keyboardObserver: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        shotObserver = NotificationCenter.default.addObserver(
            forName: Self.shotPickerNote, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let id = note.object as? String,
                  id == self.message.id else { return }
            self.showPickerRetrying(tries: 12)
        }
        keyboardObserver = NotificationCenter.default.addObserver(
            forName: Self.keyboardPickerNote, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let id = note.object as? String,
                  id == self.message.id else { return }
            self.showPicker()
        }
    }

    deinit {
        if let o = shotObserver {
            NotificationCenter.default.removeObserver(o)
        }
        if let o = keyboardObserver {
            NotificationCenter.default.removeObserver(o)
        }
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
        // No system-injected items (Ask Siri et al): this menu is exactly
        // the row + the actions below, nothing else.
        menu.allowsContextMenuPlugIns = false
        let row = NSMenuItem()
        row.view = ReactionMenuRowView(
            emojis: ConversationStore.reactionEmojis,
            menu: menu,
            anchor: self,
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
        let pin = NSMenuItem(
            title: PinnedMessages.menuTitle(isPinned: isPinned),
            action: #selector(togglePinAction), keyEquivalent: "")
        pin.target = self
        menu.addItem(pin)
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

    /// Retained while open (NSPopover is not retained by `show`).
    private var picker: NSPopover?

    /// More-picker popover above the bubble: search + recents +
    /// categories. Transient (click-outside dismisses); one pick reacts
    /// and closes. Called on the next runloop after the menu closes so
    /// menu teardown never fights popover presentation.
    func showPicker() {
        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = true
        pop.contentViewController = NSHostingController(rootView: ReactionPickerView(
            onPick: { [weak self, weak pop] emoji in
                pop?.close()
                self?.picker = nil
                self?.onReact(emoji)
            }))
        picker = pop
        pop.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
    }

    /// Shot-hook presentation: NSPopover refuses to show while the app
    /// is hidden, so retry briefly (an unhide lands mid-retry). The
    /// production ＋ path calls showPicker() directly, never this.
    private func showPickerRetrying(tries: Int) {
        showPicker()
        guard picker?.isShown != true, tries > 1 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.showPickerRetrying(tries: tries - 1)
        }
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

    @objc private func togglePinAction() {
        onTogglePin()
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

/// ＋ press target: closes the menu, then opens the more-picker
/// popover on the next runloop (menu teardown first, no fight).
private final class ReactionMenuMoreTarget: NSObject {
    let menu: NSMenu
    weak var anchor: ReactionMenuAnchorView?

    init(menu: NSMenu, anchor: ReactionMenuAnchorView) {
        self.menu = menu
        self.anchor = anchor
    }

    @objc func press() {
        menu.cancelTracking()
        DispatchQueue.main.async { [weak anchor] in anchor?.showPicker() }
    }
}

/// Horizontal emoji row for the menu item's custom view: bare emoji
/// (borderless, no focus halo) + a trailing ＋ for the more-picker.
private final class ReactionMenuRowView: NSStackView {
    private var targets: [NSObject] = []

    init(
        emojis: [String], menu: NSMenu, anchor: ReactionMenuAnchorView,
        helpFor: @escaping (String) -> String,
        onReact: @escaping (String) -> Void
    ) {
        super.init(frame: NSRect(x: 0, y: 0, width: 238, height: 30))
        orientation = .horizontal
        alignment = .centerY
        distribution = .fill
        spacing = 2
        edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 8)
        for emoji in emojis {
            let target = ReactionMenuButtonTarget(
                emoji: emoji, menu: menu, onReact: onReact)
            targets.append(target)
            addArrangedSubview(Self.bareButton(
                title: emoji, target: target,
                action: #selector(ReactionMenuButtonTarget.press),
                toolTip: helpFor(emoji)))
        }
        let more = ReactionMenuMoreTarget(menu: menu, anchor: anchor)
        targets.append(more)
        addArrangedSubview(Self.bareButton(
            title: "＋", target: more,
            action: #selector(ReactionMenuMoreTarget.press),
            toolTip: "More emoji"))
    }

    /// One bare glyph button: no bezel circle, no focus halo; the glyph
    /// dims while pressed (momentary) for press feedback.
    private static func bareButton(
        title: String, target: AnyObject?,
        action: Selector, toolTip: String
    ) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        // Borderless (no bezel circle) + no focus halo = bare glyph.
        // The default bezel style is left untouched: with isBordered
        // false no bezel draws, and no deprecated style is named.
        button.isBordered = false
        button.focusRingType = .none
        button.setButtonType(.momentaryPushIn)
        button.font = .systemFont(ofSize: 15)
        button.toolTip = toolTip
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return button
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
