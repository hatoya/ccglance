// Capture the ccglance panel region (44pt margin) as a PNG frame burst
// using ScreenCaptureKit. Usage:
//   capture <outDir> <frames> <fps>          — full burst
//   capture <outDir> 1 1 --probe             — single-frame permission probe
import AppKit
import ScreenCaptureKit

let args = CommandLine.arguments
let outDir = args[1]
let frameCount = Int(args[2])!
let fps = Double(args[3])!
let margin: CGFloat = 44

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

// Locate the ccglance panel window in global CG coordinates (y-down)
func panelRect() -> (CGRect, Int) {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
        fail("no window list")
    }
    for w in list {
        guard let owner = w[kCGWindowOwnerName as String] as? String, owner == "ccglance",
              let b = w[kCGWindowBounds as String] as? [String: CGFloat],
              let layer = w[kCGWindowLayer as String] as? Int,
              let width = b["Width"], width > 100 else { continue }
        return (CGRect(x: b["X"]!, y: b["Y"]!, width: width, height: b["Height"]!), layer)
    }
    fail("ccglance panel window not found")
}

let sema = DispatchSemaphore(value: 0)
Task {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let (rect, layer) = panelRect()
        let region = rect.insetBy(dx: -margin, dy: -margin)
        guard let display = content.displays.first(where: { $0.frame.contains(CGPoint(x: region.midX, y: region.midY)) }) else {
            fail("no display contains panel region")
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let scale = CGFloat(filter.pointPixelScale)
        let local = CGRect(
            x: region.origin.x - display.frame.origin.x,
            y: region.origin.y - display.frame.origin.y,
            width: region.width, height: region.height
        )
        let config = SCStreamConfiguration()
        config.sourceRect = local
        config.width = Int(local.width * scale)
        config.height = Int(local.height * scale)
        config.showsCursor = false
        config.captureResolution = .best

        print("panel layer=\(layer) region=\(Int(region.width))x\(Int(region.height))pt -> \(config.width)x\(config.height)px")

        let interval = 1.0 / fps
        var next = Date()
        for i in 0..<frameCount {
            let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let rep = NSBitmapImageRep(cgImage: img)
            let png = rep.representation(using: .png, properties: [:])!
            try png.write(to: URL(fileURLWithPath: String(format: "%@/frame%04d.png", outDir, i)))
            next = next.addingTimeInterval(interval)
            let wait = next.timeIntervalSinceNow
            if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
        }
        print("captured \(frameCount) frames")
        sema.signal()
    } catch {
        fail("capture error: \(error)")
    }
}
sema.wait()
