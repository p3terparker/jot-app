import Cocoa

// ============================================================================
// ToastCenter — one short, quiet message at a time, in the window you're looking at ("Copied ✓", "Saved to
// Apple Notes ✓", "Moved to Recently Deleted  [Undo]"). It replaces the old trick of overwriting the header's
// title label, which hid the note's title and let two messages race each other's reset timers.
//
//   • a dark pill near the bottom of the window (above the formatting bar), readable on any editor colour;
//   • a new message replaces the old one — they never stack or fight;
//   • 4 s on screen, paused while the pointer is over it; a click dismisses it; an optional action button (Undo);
//   • announced to VoiceOver; no fade when Reduce Motion is on.
// ============================================================================
final class ToastView: NSView {
    let label = NSTextField(labelWithString: "")
    private(set) var actionButton: NSButton?
    private var action: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?

    init(message: String, actionTitle: String?, action: (() -> Void)?) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 15
        layer?.backgroundColor = NSColor(white: 0.13, alpha: 0.96).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1, alpha: 0.14).cgColor
        label.stringValue = message
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        var trailing = label.trailingAnchor
        var gap: CGFloat = 14
        if let title = actionTitle, let action = action {
            self.action = action
            let b = NSButton(title: title, target: self, action: #selector(runAction))
            b.isBordered = false
            b.font = .systemFont(ofSize: 12, weight: .semibold)
            b.contentTintColor = NSColor(calibratedRed: 0.55, green: 0.75, blue: 1, alpha: 1)
            b.setAccessibilityLabel(title)
            b.translatesAutoresizingMaskIntoConstraints = false
            addSubview(b)
            NSLayoutConstraint.activate([b.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 10), b.centerYAnchor.constraint(equalTo: centerYAnchor)])
            actionButton = b
            trailing = b.trailingAnchor; gap = 12
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailing.constraint(equalTo: trailingAnchor, constant: -gap),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(actionTitle.map { "\(message). \($0) available." } ?? message)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func runAction() { let a = action; action = nil; onDismiss?(); a?() }
    override func mouseDown(with event: NSEvent) { onDismiss?() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

final class ToastCenter {
    static let shared = ToastCenter()
    static var duration: TimeInterval = 4

    private var live: [Int: ToastView] = [:]                 // window number → its toast
    private var timers: [Int: DispatchWorkItem] = [:]
    private(set) var history: [String] = []                  // every message shown, oldest first (the walkthrough reads this)

    func toast(in window: NSWindow?) -> ToastView? { window.flatMap { live[$0.windowNumber] } }

    func show(_ message: String, in window: NSWindow?, bottomInset: CGFloat = 0, actionTitle: String? = nil, duration: TimeInterval? = nil, action: (() -> Void)? = nil) {
        history.append(message)
        guard let window = window, let host = window.contentView else { return }
        let key = window.windowNumber
        dismiss(in: window, animated: false)

        let view = ToastView(message: message, actionTitle: actionTitle, action: action)
        view.onDismiss = { [weak self, weak window] in self?.dismiss(in: window, animated: true) }
        view.onHover = { [weak self, weak window] inside in
            guard let self = self, let window = window else { return }
            if inside { self.timers[window.windowNumber]?.cancel() } else { self.scheduleDismissal(in: window, after: 1.5) }
        }
        host.addSubview(view)
        view.layoutSubtreeIfNeeded()
        let fit = view.fittingSize
        let width = min(max(fit.width, 120), max(120, host.bounds.width - 32))
        view.frame = NSRect(x: (host.bounds.width - width) / 2, y: bottomInset + 14, width: width, height: 30)
        view.autoresizingMask = [.minXMargin, .maxXMargin, .maxYMargin]
        live[key] = view

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            view.alphaValue = 1
        } else {
            view.alphaValue = 0
            NSAnimationContext.runAnimationGroup { $0.duration = 0.15; view.animator().alphaValue = 1 }
        }
        scheduleDismissal(in: window, after: duration.map { min($0, ToastCenter.duration * 1.5 + 2) } ?? ToastCenter.duration)
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    private func scheduleDismissal(in window: NSWindow, after delay: TimeInterval) {
        let key = window.windowNumber
        timers[key]?.cancel()
        let work = DispatchWorkItem { [weak self, weak window] in self?.dismiss(in: window, animated: true) }
        timers[key] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func dismiss(in window: NSWindow?, animated: Bool) {
        guard let window = window else { return }
        let key = window.windowNumber
        timers[key]?.cancel(); timers[key] = nil
        guard let view = live.removeValue(forKey: key) else { return }
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            animateWithFallback(duration: 0.15, { view.animator().alphaValue = 0 }, done: { view.removeFromSuperview() })
        } else {
            view.removeFromSuperview()
        }
    }
}
