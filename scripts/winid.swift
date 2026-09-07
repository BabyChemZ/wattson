import Foundation
import CoreGraphics

let appName = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Wattson"
guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements],
                                            kCGNullWindowID) as? [[String: Any]] else { exit(1) }
let matches = list.filter { info in
    guard let owner = info[kCGWindowOwnerName as String] as? String,
          owner.localizedCaseInsensitiveContains(appName) else { return false }
    let bounds = info[kCGWindowBounds as String] as? [String: Any]
    let w = (bounds?["Width"] as? Double) ?? 0
    let h = (bounds?["Height"] as? Double) ?? 0
    return w > 800 && h > 400
}
guard let window = matches.first,
      let number = window[kCGWindowNumber as String] as? Int else {
    FileHandle.standardError.write("no window\n".data(using: .utf8)!); exit(2)
}
let b = window[kCGWindowBounds as String] as? [String: Any]
FileHandle.standardError.write(
    "window \(Int((b?["Width"] as? Double) ?? 0))x\(Int((b?["Height"] as? Double) ?? 0))\n"
        .data(using: .utf8)!)
print(number)
