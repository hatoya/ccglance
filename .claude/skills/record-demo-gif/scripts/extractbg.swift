// Extract a still frame from the macOS aerial screensaver movie for the
// demo background (borrowed-scenery window behind the panel).
import AVFoundation
import AppKit

let movPath = CommandLine.arguments[1]
let outPath = CommandLine.arguments[2]

let asset = AVAsset(url: URL(fileURLWithPath: movPath))
let gen = AVAssetImageGenerator(asset: asset)
gen.appliesPreferredTrackTransform = true
gen.requestedTimeToleranceBefore = .zero
gen.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)

let time = CMTime(seconds: 30, preferredTimescale: 600)
let cg = try gen.copyCGImage(at: time, actualTime: nil)
let rep = NSBitmapImageRep(cgImage: cg)
let png = rep.representation(using: .png, properties: [:])!
try png.write(to: URL(fileURLWithPath: outPath))
print("bg: \(cg.width)x\(cg.height) -> \(outPath)")
