// Decode the GIF with ImageIO and dump selected composited frames as PNGs.
import AppKit
import ImageIO

let gifPath = CommandLine.arguments[1]
let outDir = CommandLine.arguments[2]

let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: gifPath) as CFURL, nil)!
let count = CGImageSourceGetCount(src)
print("frames: \(count)")

var totalDelay = 0.0
for i in 0..<count {
    let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as! [String: Any]
    let gifProps = props[kCGImagePropertyGIFDictionary as String] as! [String: Any]
    totalDelay += gifProps[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double ?? 0
}
print(String(format: "total duration: %.1fs", totalDelay))

for i in [0, 60, 110, 180, 239] where i < count {
    guard let img = CGImageSourceCreateImageAtIndex(src, i, nil) else {
        print("frame \(i): DECODE FAILED"); exit(1)
    }
    print("frame \(i): \(img.width)x\(img.height)")
    let rep = NSBitmapImageRep(cgImage: img)
    let png = rep.representation(using: .png, properties: [:])!
    try png.write(to: URL(fileURLWithPath: "\(outDir)/decoded\(i).png"))
}
print("OK")
