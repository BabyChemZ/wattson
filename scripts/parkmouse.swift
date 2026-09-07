import CoreGraphics
import AppKit

// Park the pointer clear of the window before a capture. Hovering produces
// tooltips, quit buttons and highlighted chart columns — all correct
// behaviour, and all of it noise in a screenshot that is supposed to show the
// page at rest.
let screen = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
CGWarpMouseCursorPosition(CGPoint(x: screen.maxX - 2, y: screen.maxY - 2))
