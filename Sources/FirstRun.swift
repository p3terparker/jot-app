import Cocoa
import Carbon
import ServiceManagement

// ============================================================================
// FirstRun — what the first launch does, and the start-up choices that must never surprise anyone:
//   • the default shortcut is decided once and written down (HotkeyDefaults: new installs ⌥⌘J, existing ones keep ⌃J);
//   • a brand-new install gets a real "Welcome to Jot" note and the pad opens on it, so nobody has to hunt for the menu-bar icon;
//   • "Open at login" is the person's choice: nothing registers it behind their back, and the setting shows the SYSTEM's state.
// ============================================================================
extension AppDelegate {
    @discardableResult
    func resolveHotkeyDefaults() -> HotkeyDefaults.Resolved {
        let resolved = HotkeyDefaults.resolve(
            storedKeyCode: Prefs.d.object(forKey: "hotkeyKeyCode") as? Int, storedCarbon: Prefs.d.object(forKey: "hotkeyCarbon") as? Int,
            storedDisplay: Prefs.d.string(forKey: "hotkeyDisplay"), hasShownWelcome: Prefs.hasShownWelcome)
        if resolved.persist { Prefs.hotkeyKeyCode = UInt32(resolved.keyCode); Prefs.hotkeyCarbon = UInt32(resolved.carbon); Prefs.hotkeyDisplay = resolved.display }
        return resolved
    }

    // A new install (never welcomed, no notes at all) gets the welcome note. Returns it.
    @discardableResult
    func seedWelcomeNoteIfNeeded(into target: NotesStore? = nil) -> URL? {
        guard !Prefs.hasShownWelcome else { return nil }
        Prefs.hasShownWelcome = true
        let library = target ?? store
        guard library.all().isEmpty else { return nil }                 // someone with notes already isn't new
        do {
            let url = try library.create()
            try WelcomeNote.body(hotkey: Prefs.hotkeyDisplay).write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch { return nil }
    }

    // MARK: open at login — the system's state is the truth
    var loginItemStatus: SMAppService.Status? {
        if Runtime.isPreview { return nil }
        if #available(macOS 13.0, *) { return SMAppService.mainApp.status }
        return nil
    }
    var loginItemEnabled: Bool { loginItemStatus == .enabled }
    var loginItemNeedsApproval: Bool { loginItemStatus == .requiresApproval }

    func setLoginItem(_ on: Bool) {
        if Runtime.isPreview { PreviewLog.record("login-item", on ? "on" : "off"); return }
        guard #available(macOS 13.0, *) else { return }
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { flash("Couldn't change Open at Login: \(error.localizedDescription)") }
        if on, loginItemNeedsApproval { SMAppService.openSystemSettingsLoginItems() }
    }
    @objc func toggleLoginItem() { setLoginItem(!loginItemEnabled) }

    // MARK: About
    @objc func showAbout() {
        let credits = NSMutableAttributedString(string: "A quick-capture notepad for your menu bar.\n\nYour notes are plain Markdown files on your Mac. Jot makes no network connections and sends nothing anywhere unless you choose Share.\n")
        credits.addAttributes([.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor], range: NSRange(location: 0, length: credits.length))
        jotActivate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}
