// Reads a running app's windows through the accessibility tree (for the scripted UI checks; macOS asks
// once for Accessibility permission for the terminal running it).
//   axdump <pid>                      prints each window's text: role, then title | value | description
//   axdump <pid> - "<text>"           presses the button or menu item whose text is <text> or starts with "<text>,"
//   axdump <pid> key <code>           sends one key press (virtual key code) to the app
//   axdump <pid> visible "<text>"     exits 0 when the element with that text lies inside its window (layout that
//                                     overflows the window still shows up in the tree, so reading it isn't enough)
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
// axdump <pid> key <code>: a key press (down and up) sent to that app (the scripted checks' controller stand-in)
if CommandLine.arguments.count > 3, CommandLine.arguments[2] == "key", let code = CGKeyCode(CommandLine.arguments[3]) {
    for down in [true, false] {
        CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)?.postToPid(pid)
        usleep(30_000)
    }
    print(">>> key \(code)")
    exit(0)
}
func frame(_ e: AXUIElement) -> CGRect? {
    guard let p = attr(e, kAXPositionAttribute), let s = attr(e, kAXSizeAttribute) else { return nil }
    var point = CGPoint.zero, size = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &point)
    AXValueGetValue(s as! AXValue, .cgSize, &size)
    return CGRect(origin: point, size: size)
}
func find(_ e: AXUIElement, _ wanted: String) -> AXUIElement? {
    let t = text(e)
    if t == wanted || t.hasPrefix(wanted + ",") { return e }
    for c in children(e) { if let hit = find(c, wanted) { return hit } }
    return nil
}
if CommandLine.arguments.count > 3, CommandLine.arguments[2] == "visible" {
    let wanted = CommandLine.arguments[3]
    for w in windows {
        guard let hit = find(w, wanted), let f = frame(hit), let wf = frame(w) else { continue }
        let inside = wf.insetBy(dx: -1, dy: -1).contains(f)
        print("\(inside ? "visible" : "outside"): \(wanted) at \(f) in window \(wf)")
        exit(inside ? 0 : 1)
    }
    print("!!! nothing named \(wanted)")
    exit(1)
}
if press != nil {
    for w in windows { for sheet in sheets(w) where press != nil { _ = findPress(sheet) } }
    if press != nil, let bar = attr(app, kAXMenuBarAttribute) { _ = findPress(bar as! AXUIElement) }
    for w in windows where press != nil { _ = findPress(w) }
    if press != nil { print("!!! nothing to press named \(press!)"); exit(1) }
} else {
    for w in windows { print("== window: " + text(w)); walk(w, 1) }
}
