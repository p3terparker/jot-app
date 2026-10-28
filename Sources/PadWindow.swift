import Cocoa

// ============================================================================
// PadWindow — how the pad appears and goes away.
//
//   • Show: a ~140 ms fade with a 6 pt rise into place. Hide: a ~120 ms fade, then the window is ordered out.
//     Reduce Motion (and the preview harness, unless a test asks for it) skips the motion entirely.
//   • A generation token and a "hiding" flag make rapid toggles safe: a hide that was overtaken by a show never
//     orders the window out, and a second hotkey press during a fade means what you meant (show again).
//   • Placement: under the menu-bar icon when it is on a screen; otherwise (the notch or a crowded menu bar hides
//     it) at the top centre of the screen the mouse is on. Always clamped into the visible screen area.
//   • Size is remembered every time the pad is resized; position only once you have dragged it away (detached).
// ============================================================================
// Runs an AppKit animation and guarantees `done` runs once, shortly after it should have ended — even if the display is asleep,
// the screen is locked or the system has suspended animations, when AppKit never ticks (or completes) them. The final state of a
// window, drawer or toast must never depend on a frame being drawn.
func animateWithFallback(duration: TimeInterval, timing: CAMediaTimingFunctionName = .easeInEaseOut, _ changes: @escaping () -> Void, done: @escaping () -> Void) {
    var finished = false
    let finish = { if !finished { finished = true; done() } }
    NSAnimationContext.runAnimationGroup({ context in
        context.duration = duration
        context.timingFunction = CAMediaTimingFunction(name: timing)
        changes()
    }, completionHandler: finish)
    DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.08, execute: finish)
}

extension AppDelegate {
    static let padShowDuration: TimeInterval = 0.14
    static let padHideDuration: TimeInterval = 0.12
    static let padRise: CGFloat = 6
    static var previewAnimations = false     // the walkthrough turns this on for the checks that exercise the motion

    static var previewMouseDown = false      // a preview never reads the real mouse: the walkthrough says whether "the button is down"
    var leftMouseIsDown: Bool { Runtime.isPreview ? AppDelegate.previewMouseDown : NSEvent.pressedMouseButtons & 1 != 0 }

    var animatesPad: Bool {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return false }
        return !Runtime.isPreview || AppDelegate.previewAnimations
    }
    // Showing, or fading in: what the user means by "the pad is open".
    var isPadShowing: Bool { dropdown.isVisible && !padHiding }

    // A preview never takes keyboard focus (its pad is parked off-screen); a real pad does.
    private func orderPadIn() {
        if Runtime.snapshotDirectory != nil { dropdown.orderFrontRegardless() } else { dropdown.makeKeyAndOrderFront(nil); jotActivate() }
    }

    func showPad() {
        padGeneration += 1
        padHiding = false
        let final = dropdown.frame
        guard animatesPad else {
            dropdown.alphaValue = 1
            orderPadIn()
            return
        }
        let token = padGeneration
        var start = final; start.origin.y -= AppDelegate.padRise
        suppressMoveSave = true
        dropdown.alphaValue = 0
        dropdown.setFrame(start, display: false)
        orderPadIn()
        animateWithFallback(duration: AppDelegate.padShowDuration, timing: .easeOut, {
            self.dropdown.animator().alphaValue = 1
            self.dropdown.animator().setFrame(final, display: true)
        }, done: { [weak self] in
            guard let self = self, token == self.padGeneration else { return }
            self.dropdown.alphaValue = 1
            self.dropdown.setFrame(final, display: true)
            self.suppressMoveSave = false
        })
    }

    func hidePad() {
        guard dropdown.isVisible else { return }
        padGeneration += 1
        guard animatesPad else { padHiding = false; dropdown.orderOut(nil); dropdown.alphaValue = 1; return }
        padHiding = true
        let token = padGeneration
        animateWithFallback(duration: AppDelegate.padHideDuration, timing: .easeIn, {
            self.dropdown.animator().alphaValue = 0
        }, done: { [weak self] in
            guard let self = self, token == self.padGeneration else { return }     // shown again meanwhile: leave it alone
            self.padHiding = false
            self.dropdown.orderOut(nil)
            self.dropdown.alphaValue = 1
        })
    }

    // MARK: placement
    // The screen the user is working on: the one with the pointer.
    private var screenUnderMouse: NSScreen? {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main
    }
    // `frame` moved (never resized) so it lies inside the visible area of the screen that holds most of it.
    func fitted(_ frame: NSRect, on screen: NSScreen? = nil) -> NSRect {
        guard let visible = (screen ?? NSScreen.screens.max { NSIntersectionRect($0.visibleFrame, frame).width * NSIntersectionRect($0.visibleFrame, frame).height
                                                          < NSIntersectionRect($1.visibleFrame, frame).width * NSIntersectionRect($1.visibleFrame, frame).height } ?? NSScreen.main)?.visibleFrame else { return frame }
        var f = frame
        f.origin.x = min(max(f.origin.x, visible.minX + 8), max(visible.minX + 8, visible.maxX - f.width - 8))
        f.origin.y = min(max(f.origin.y, visible.minY + 8), max(visible.minY + 8, visible.maxY - f.height - 8))
        return f
    }
    // Under the menu-bar icon; at the top centre of the pointer's screen when the icon isn't visible anywhere.
    func positionUnderStatusItem() {
        var frame = dropdown.frame
        if let button = statusItem?.button, let window = button.window,
           NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) }) {
            let onScreen = window.convertToScreen(button.convert(button.bounds, to: nil))
            frame.origin.x = onScreen.midX - frame.width / 2
            frame.origin.y = onScreen.minY - frame.height - 4
            dropdown.setFrame(fitted(frame, on: window.screen), display: false)
        } else if let screen = screenUnderMouse {
            frame.origin.x = screen.visibleFrame.midX - frame.width / 2
            frame.origin.y = screen.visibleFrame.maxY - frame.height - 12
            dropdown.setFrame(fitted(frame, on: screen), display: false)
        }
    }

    // MARK: size memory
    static let sizeKey = "jotSize"
    var rememberedPadSize: NSSize? {
        guard let s = Prefs.d.string(forKey: AppDelegate.sizeKey) else { return nil }
        let size = NSSizeFromString(s)
        return size.width >= 360 && size.height >= 240 ? size : nil
    }
    func rememberPadSize() { Prefs.d.set(NSStringFromSize(dropdown.frame.size), forKey: AppDelegate.sizeKey) }
    func restorePadSize() {
        guard let size = rememberedPadSize else { return }
        var f = dropdown.frame
        f.origin.y += f.height - size.height            // keep the top edge where it was
        f.size = size
        dropdown.setFrame(f, display: false)
    }
}
