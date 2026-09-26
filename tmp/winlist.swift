// winlist.swift — print on-screen windows for a PID: "<id> <w>x<h> <name>".
import CoreGraphics

let pid = pid_t(Int(CommandLine.arguments[1]) ?? 0)
let infos = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
for w in infos {
    guard (w[kCGWindowOwnerPID as String] as? Int32) == pid else { continue }
    guard let b = w[kCGWindowBounds as String] as? [String: Any],
        let width = b["Width"] as? Double, width > 200,
        let id = w[kCGWindowNumber as String] as? Int,
        let height = b["Height"] as? Double
    else { continue }
    let name = (w[kCGWindowName as String] as? String) ?? ""
    print("\(id) \(Int(width))x\(Int(height)) \(name)")
}
