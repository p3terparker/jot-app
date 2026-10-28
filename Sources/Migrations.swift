import Foundation

// ============================================================================
// Migrations — decisions about stored settings that must never surprise an existing user.
// ============================================================================

// Hotkey defaults. A global shortcut is muscle memory, so changing the default must never move an
// existing user's key:
//   • keys already stored win and are never rewritten;
//   • someone who has run Jot before but never customised it (`hasShownWelcome`) keeps the legacy ⌃J,
//     and it is written down so a later default change can't touch it;
//   • a brand-new install gets ⌥⌘J — and it is written down too, otherwise its *second* launch would look
//     like a veteran's and flip it to ⌃J.
// Carbon key codes (spelled out so this file stays Foundation-only; the app asserts they match):
//   kVK_ANSI_J = 38, controlKey = 4096, optionKey = 2048, cmdKey = 256.
enum HotkeyDefaults {
    struct Resolved: Equatable {
        let keyCode: Int
        let carbon: Int
        let display: String
        let persist: Bool          // write these three values to the preferences
    }
    static let legacy = (keyCode: 38, carbon: 4096, display: "⌃J")
    static let current = (keyCode: 38, carbon: 2048 | 256, display: "⌥⌘J")

    static func resolve(storedKeyCode: Int?, storedCarbon: Int?, storedDisplay: String?, hasShownWelcome: Bool) -> Resolved {
        if storedKeyCode != nil || storedCarbon != nil || storedDisplay != nil {
            return Resolved(keyCode: storedKeyCode ?? legacy.keyCode, carbon: storedCarbon ?? legacy.carbon,
                            display: storedDisplay ?? legacy.display, persist: false)
        }
        let chosen = hasShownWelcome ? legacy : current
        return Resolved(keyCode: chosen.keyCode, carbon: chosen.carbon, display: chosen.display, persist: true)
    }
}
