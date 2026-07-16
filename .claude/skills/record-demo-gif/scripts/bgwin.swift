// Borrowed-scenery background window: covers exactly the capture region
// (panel + 44pt margin) with the aerial image aspect-filled, one window
// level below the panel. Sized to the region — NOT the display — so the
// whole image frames the panel like the original README GIF.
import AppKit

let imgPath = CommandLine.arguments[1]

func panelInfo() -> (CGRect, Int)? {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
    for w in list {
        guard let owner = w[kCGWindowOwnerName as String] as? String, owner == "ccglance",
              let b = w[kCGWindowBounds as String] as? [String: CGFloat],
              let layer = w[kCGWindowLayer as String] as? Int,
              let width = b["Width"], width > 100 else { continue }
        return (CGRect(x: b["X"]!, y: b["Y"]!, width: width, height: b["Height"]!), layer)
    }
    return nil
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// Wait until the panel exists AND has grown to the demo layout height,
// otherwise the window gets sized to the empty panel.
var info: (CGRect, Int)?
for _ in 0..<100 {
    info = panelInfo()
    if let (r, _) = info, r.height >= 250 { break }
    Thread.sleep(forTimeInterval: 0.2)
}
guard let (cgRect, layer) = info, cgRect.height >= 250 else {
    FileHandle.standardError.write("panel not found or not grown\n".data(using: .utf8)!)
    exit(1)
}

// Window frame = capture region, converted from CG coords (y-down from
// main display top-left) to Cocoa coords (y-up).
let margin: CGFloat = 44
let region = cgRect.insetBy(dx: -margin, dy: -margin)
let mainH = NSScreen.screens[0].frame.height
let cocoaFrame = NSRect(
    x: region.origin.x,
    y: mainH - region.origin.y - region.height,
    width: region.width, height: region.height
)

let win = NSWindow(contentRect: cocoaFrame, styleMask: .borderless, backing: .buffered, defer: false)
win.level = NSWindow.Level(rawValue: layer - 1)
win.isOpaque = true
win.ignoresMouseEvents = true
win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

let view = NSView(frame: NSRect(origin: .zero, size: cocoaFrame.size))
view.wantsLayer = true
view.layer?.contents = NSImage(contentsOfFile: imgPath)
view.layer?.contentsGravity = .resizeAspectFill
win.contentView = view
win.orderFrontRegardless()
print("bgwin up on \(Int(region.width))x\(Int(region.height))pt at level \(layer - 1)")

signal(SIGTERM) { _ in exit(0) }
signal(SIGINT) { _ in exit(0) }
app.run()
