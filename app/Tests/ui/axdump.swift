// Reads a running app's windows through the accessibility tree (for the scripted UI checks; macOS asks
// once for Accessibility permission for the terminal running it).
//   axdump <pid>                      prints each window's text: role, then title | value | description
//   axdump <pid> - "<text>"           presses the button or menu item whose text is <text> or starts with "<text>,"
// Disabled controls end with " (disabled)". Sheets and dialogs are searched before the window under them.
import ApplicationServices
import Foundation

let pid = pid_t(CommandLine.arguments[1])!
let app = AXUIElementCreateApplication(pid)
func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?; AXUIElementCopyAttributeValue(e, name as CFString, &v); return v
}
func text(_ e: AXUIElement) -> String {
    [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute].compactMap { attr(e, $0 as String) as? String }
        .filter { !$0.isEmpty }.joined(separator: " | ")
}
func children(_ e: AXUIElement) -> [AXUIElement] { attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
func walk(_ e: AXUIElement, _ depth: Int) {
    let role = attr(e, kAXRoleAttribute) as? String ?? "?"
    let t = text(e)
    let disabled = (attr(e, kAXEnabledAttribute) as? Bool) == false ? " (disabled)" : ""
    if !t.isEmpty || role == "AXSheet" { print(String(repeating: "  ", count: depth) + role + ": " + t + disabled) }
    for c in children(e) { walk(c, depth + 1) }
}
var press = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : nil
func findPress(_ e: AXUIElement) -> Bool {
    let role = attr(e, kAXRoleAttribute) as? String ?? ""
    if let wanted = press, role == "AXButton" || role == "AXMenuItem" || role == "AXMenuBarItem" {
        let t = text(e)
        if t == wanted || t.hasPrefix(wanted + ",") {
            AXUIElementPerformAction(e, kAXPressAction as CFString); print(">>> pressed \(wanted)"); press = nil; return true
        }
    }
    for c in children(e) where findPress(c) { return true }
    return false
}
func sheets(_ e: AXUIElement) -> [AXUIElement] {
    let kids = children(e)
    return kids.filter { ["AXSheet", "AXDialog"].contains(attr($0, kAXRoleAttribute) as? String ?? "") } + kids.flatMap(sheets)
}
let windows = attr(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
if press != nil {
    for w in windows { for sheet in sheets(w) where press != nil { _ = findPress(sheet) } }
    if press != nil, let bar = attr(app, kAXMenuBarAttribute) { _ = findPress(bar as! AXUIElement) }
    for w in windows where press != nil { _ = findPress(w) }
    if press != nil { print("!!! nothing to press named \(press!)"); exit(1) }
} else {
    for w in windows { print("== window: " + text(w)); walk(w, 1) }
}
