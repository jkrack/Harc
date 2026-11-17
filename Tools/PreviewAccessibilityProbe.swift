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
walk(application, depth: 0)
