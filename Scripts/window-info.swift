// Prints the on-screen window geometry for a process, as "id x y w h".
//
// Used by Scripts/screenshot.sh, which needs a window id for `screencapture -l`
// so the capture contains just the app's window and nothing else on screen.
//
//     swift Scripts/window-info.swift 1234
import CoreGraphics
import Foundation

guard CommandLine.arguments.count > 1, let pid = Int32(CommandLine.arguments[1]) else {
    FileHandle.standardError.write(Data("usage: window-info <pid>\n".utf8))
    exit(2)
}

let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []

// Layer 0 is the normal window layer; anything else is a panel, menu or overlay.
var best: (area: CGFloat, id: Int, bounds: CGRect)?
for window in windows {
    guard let owner = window[kCGWindowOwnerPID as String] as? Int, owner == Int(pid) else { continue }
    guard (window[kCGWindowLayer as String] as? Int) == 0 else { continue }
    guard let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] else { continue }

    let frame = CGRect(
        x: bounds["X"] ?? 0,
        y: bounds["Y"] ?? 0,
        width: bounds["Width"] ?? 0,
        height: bounds["Height"] ?? 0
    )
    // The largest normal window is the browser; smaller ones are sheets.
    let area = frame.width * frame.height
    if best == nil || area > best!.area {
        best = (area, window[kCGWindowNumber as String] as? Int ?? 0, frame)
    }
}

guard let found = best else { exit(1) }

print("\(found.id) \(Int(found.bounds.minX)) \(Int(found.bounds.minY)) \(Int(found.bounds.width)) \(Int(found.bounds.height))")
