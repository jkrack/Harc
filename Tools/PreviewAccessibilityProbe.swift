// Read-only synthetic QA client. Explicit test PID only; never prompts for trust.
import Foundation
import ApplicationServices

guard CommandLine.arguments.count == 2, let pid = Int32(CommandLine.arguments[1]), pid > 0 else {
    fatalError("Supply the synthetic test process PID.")
}
guard AXIsProcessTrusted() else {
    print("AX client not trusted; no prompt or permission change attempted.")
    exit(2)
}
// Wall-clock bound includes all attributes/nodes, even a stalled AX server.
DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
    print("Whole-process AX watchdog expired after 20 seconds.")
    fflush(stdout)
    exit(124)
}
let application = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(application, 2)
var count = 0
func read(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    guard result == .success else {
        print("AX read failed: \(name), error \(result.rawValue)")
        return nil
    }
    return value
}
func walk(_ element: AXUIElement, depth: Int) {
    guard depth < 32, count < 1000 else { return }
    // Defense in depth: no menu traversal even if exposed below a window.
    if let role = read(element, "AXRole") as? String,
       ["AXMenuBar", "AXMenuBarItem", "AXMenu", "AXMenuItem"].contains(role) { return }
    count += 1
    for name in ["AXRole", "AXTitle", "AXDescription", "AXValue", "AXIdentifier"] {
        if let value = read(element, name) as? String {
            print("\(depth) \(name): \(value)")
        }
    }
    let children = read(element, "AXChildren") as? [AXUIElement] ?? []
    for child in children { walk(child, depth: depth + 1) }
}
print("Trusted actual AX client; synthetic target PID \(pid)")
// Never walk application children: inherited menu bars can expose Recent Items.
// Read only the fixed role, then descend into exact synthetic fixture windows.
if let role = read(application, "AXRole") as? String, role == "AXApplication" {
    print("0 AXRole: AXApplication")
} else { exit(3) }
let allowedTitles: Set<String> = [
    "Synthetic Harc preview", "Synthetic native controls", "Synthetic SwiftUI controls"
]
let windows = read(application, "AXWindows") as? [AXUIElement] ?? []
var matched = Set<String>()
for window in windows {
    guard let title = read(window, "AXTitle") as? String,
          allowedTitles.contains(title) else { continue }
    matched.insert(title)
    walk(window, depth: 1)
}
guard matched == allowedTitles else {
    print("Required synthetic windows unavailable; refusing incomplete qualification.")
    exit(4)
}
