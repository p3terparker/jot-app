import Foundation

// ============================================================================
// SendErrors — what to tell the person when sending a note to another app fails. Pure Foundation (test.sh checks the table):
// the Apple Event error numbers are macOS's; the sentences are ours, and each says what to DO.
// ============================================================================
enum SendErrors {
    struct Message: Equatable {
        var text: String
        var opensAutomationSettings = false      // offer a button that opens System Settings ▸ Privacy & Security ▸ Automation
        var opensAccessibilitySettings = false
    }

    static func appleNotes(code: Int) -> Message {
        switch code {
        case -1743: return Message(text: "Jot isn't allowed to control Notes", opensAutomationSettings: true)
        case -1744: return Message(text: "macOS wants your OK for Jot to control Notes — allow it, then send again")
        case -600:  return Message(text: "Notes isn't running and couldn't be opened")
        case -128:  return Message(text: "Cancelled")
        default:    return Message(text: "Apple Notes didn't accept the note (error \(code))")
        }
    }

    // AppleScript reports a missing Accessibility grant three different ways; the last (1002) is the one seen in practice.
    static func stickies(code: Int, message: String) -> Message {
        if [-1719, -25211, 1002].contains(code) || message.lowercased().contains("not allowed to send keystrokes") {
            return Message(text: "Stickies needs Accessibility for Jot", opensAccessibilitySettings: true)
        }
        if code == -1743 { return Message(text: "Jot isn't allowed to control Stickies", opensAutomationSettings: true) }
        return Message(text: "Stickies didn't accept the note (error \(code))")
    }
}
