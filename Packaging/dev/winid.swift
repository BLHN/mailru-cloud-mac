import CoreGraphics
import Foundation
let pid = Int32(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]]
for w in list where (w["kCGWindowOwnerPID"] as? Int32) == pid {
    let b = w["kCGWindowBounds"] as? [String: Any] ?? [:]
    print(w["kCGWindowNumber"] as! Int, "xy", b["X"] ?? 0, b["Y"] ?? 0, "layer", w["kCGWindowLayer"] as? Int ?? 0, "onscreen", w["kCGWindowIsOnscreen"] as? Bool ?? false, "name", w["kCGWindowName"] as? String ?? "", b["Width"] ?? 0, "x", b["Height"] ?? 0)
}
