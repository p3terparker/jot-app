import Foundation

// ============================================================================
// SidebarGeometry — where every piece of the notes sidebar goes, as a pure function of the pad's size (Foundation only, so
// test.sh can sweep it). Below 560 pt wide the list is a DRAWER over the text (the text keeps its full width); from 560 pt
// it DOCKS beside the text, which always keeps at least 300 pt. See Sidebar.swift for the views and the motion.
// ============================================================================
struct SidebarGeometry {
    var filter: NSRect, list: NSRect, backdrop: NSRect, divider: NSRect, scrim: NSRect, editor: NSRect
    var docked: Bool

    static let dockThreshold: CGFloat = 560
    static let minimumTextColumn: CGFloat = 300
    static let drawerMaximum: CGFloat = 280

    static func drawerWidth(_ saved: CGFloat, window W: CGFloat) -> CGFloat { min(max(200, min(saved, drawerMaximum)), max(200, W - 56)) }
    static func dockWidth(_ saved: CGFloat, window W: CGFloat) -> CGFloat { min(max(180, saved), max(180, W - minimumTextColumn - 4)) }

    // `bottom` = the height of whatever sits under the text (the formatting bar); `bodyHeight` = the area between it and the header.
    static func compute(width W: CGFloat, bodyHeight bodyH: CGFloat, bottom: CGFloat, shown: Bool, savedWidth: CGFloat) -> SidebarGeometry {
        let docked = W >= dockThreshold
        let w = docked ? dockWidth(savedWidth, window: W) : drawerWidth(savedWidth, window: W)
        let x: CGFloat = shown ? 0 : -(w + 4)                       // hidden: parked just off the left edge, so it slides in
        let listHeight = max(0, bodyH - 44)
        let filter = NSRect(x: x + 12, y: bottom + bodyH - 36, width: w - 24, height: 26)       // the search field sits above the list
        let list = NSRect(x: x, y: bottom, width: w, height: listHeight)
        let backdrop = NSRect(x: x, y: bottom, width: w, height: bodyH)
        if docked {
            let divider = NSRect(x: x + w, y: bottom, width: 4, height: bodyH)
            let editor = shown ? NSRect(x: w + 4, y: bottom, width: max(0, W - w - 4), height: bodyH) : NSRect(x: 0, y: bottom, width: W, height: bodyH)
            return SidebarGeometry(filter: filter, list: list, backdrop: backdrop, divider: divider, scrim: .zero, editor: editor, docked: true)
        }
        let divider = NSRect(x: x + w, y: bottom, width: 1, height: bodyH)
        let scrim = NSRect(x: w, y: bottom, width: max(0, W - w), height: bodyH)
        return SidebarGeometry(filter: filter, list: list, backdrop: backdrop, divider: divider, scrim: scrim,
                               editor: NSRect(x: 0, y: bottom, width: W, height: bodyH), docked: false)
    }
}
