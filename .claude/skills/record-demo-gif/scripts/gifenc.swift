// GIF encoder tuned for screen-recording loops:
//  - one global median-cut palette (255 colors, index 255 reserved transparent)
//  - Bayer 8x8 ordered dither (position-deterministic -> static areas are
//    bit-identical across frames, so inter-frame diffs stay tiny)
//  - frame diff with disposal=1, only the changed bounding box is written
//  - hand-rolled LZW
// Usage: gifenc <framesDir> <out.gif> <delayCentisec>
import AppKit

let framesDir = CommandLine.arguments[1]
let outPath = CommandLine.arguments[2]
let delayCS = Int(CommandLine.arguments[3])!
let ditherStrength = 8.0

// MARK: load frames as RGB888

func loadRGB(_ path: String) -> (w: Int, h: Int, px: [UInt8]) {
    guard let img = NSImage(contentsOfFile: path),
          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        fatalError("cannot load \(path)")
    }
    let w = cg.width, h = cg.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                        bytesPerRow: w * 4, space: cs,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    var rgb = [UInt8](repeating: 0, count: w * h * 3)
    for i in 0..<(w * h) {
        rgb[i * 3] = buf[i * 4]
        rgb[i * 3 + 1] = buf[i * 4 + 1]
        rgb[i * 3 + 2] = buf[i * 4 + 2]
    }
    return (w, h, rgb)
}

let files = try FileManager.default.contentsOfDirectory(atPath: framesDir)
    .filter { $0.hasSuffix(".png") }.sorted()
guard !files.isEmpty else { fatalError("no frames") }
print("frames: \(files.count)")

let first = loadRGB(framesDir + "/" + files[0])
let W = first.w, H = first.h
print("size: \(W)x\(H)")

// MARK: median-cut palette from sampled pixels across all frames

struct Box {
    var pixels: [UInt32]  // packed RGB
    func channelRanges() -> (r: Int, g: Int, b: Int) {
        var rMin = 255, rMax = 0, gMin = 255, gMax = 0, bMin = 255, bMax = 0
        for p in pixels {
            let r = Int((p >> 16) & 0xFF), g = Int((p >> 8) & 0xFF), b = Int(p & 0xFF)
            rMin = min(rMin, r); rMax = max(rMax, r)
            gMin = min(gMin, g); gMax = max(gMax, g)
            bMin = min(bMin, b); bMax = max(bMax, b)
        }
        return (rMax - rMin, gMax - gMin, bMax - bMin)
    }
}

var samples: [UInt32] = []
samples.reserveCapacity(4_000_000)
let sampleStride = max(1, files.count * W * H / 3_000_000)
var counter = 0
for (fi, f) in files.enumerated() {
    let fr = fi == 0 ? first : loadRGB(framesDir + "/" + f)
    precondition(fr.w == W && fr.h == H, "frame size mismatch: \(f)")
    var i = counter % sampleStride
    while i < W * H {
        let p = UInt32(fr.px[i*3]) << 16 | UInt32(fr.px[i*3+1]) << 8 | UInt32(fr.px[i*3+2])
        samples.append(p)
        i += sampleStride
    }
    counter += W * H
}
print("palette samples: \(samples.count)")

var boxes = [Box(pixels: samples)]
while boxes.count < 255 {
    guard let (bi, _) = boxes.enumerated()
        .filter({ $0.element.pixels.count > 1 })
        .max(by: {
            let ra = $0.element.channelRanges(), rb = $1.element.channelRanges()
            return max(ra.r, ra.g, ra.b) < max(rb.r, rb.g, rb.b)
        }) else { break }
    var box = boxes.remove(at: bi)
    let ranges = box.channelRanges()
    let shift: UInt32 = ranges.r >= ranges.g && ranges.r >= ranges.b ? 16 : (ranges.g >= ranges.b ? 8 : 0)
    box.pixels.sort { (($0 >> shift) & 0xFF) < (($1 >> shift) & 0xFF) }
    let mid = box.pixels.count / 2
    boxes.append(Box(pixels: Array(box.pixels[..<mid])))
    boxes.append(Box(pixels: Array(box.pixels[mid...])))
}

var palette = [(UInt8, UInt8, UInt8)]()
for box in boxes {
    var rs = 0, gs = 0, bs = 0
    for p in box.pixels {
        rs += Int((p >> 16) & 0xFF); gs += Int((p >> 8) & 0xFF); bs += Int(p & 0xFF)
    }
    let n = max(1, box.pixels.count)
    palette.append((UInt8(rs / n), UInt8(gs / n), UInt8(bs / n)))
}
while palette.count < 255 { palette.append((0, 0, 0)) }
print("palette: \(palette.count) colors")

// MARK: nearest-color lookup cache

var nearestCache = [UInt32: UInt8]()
nearestCache.reserveCapacity(1 << 20)
@inline(__always) func nearest(_ r: Int, _ g: Int, _ b: Int) -> UInt8 {
    let key = UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b)
    if let hit = nearestCache[key] { return hit }
    var best = 0, bestD = Int.max
    for (i, c) in palette.enumerated() {
        let dr = r - Int(c.0), dg = g - Int(c.1), db = b - Int(c.2)
        let d = dr * dr + dg * dg + db * db
        if d < bestD { bestD = d; best = i }
    }
    nearestCache[key] = UInt8(best)
    return UInt8(best)
}

let bayer: [[Double]] = {
    var m = [[Double]](repeating: [Double](repeating: 0, count: 8), count: 8)
    let base2 = [[0, 2], [3, 1]]
    func value(_ x: Int, _ y: Int) -> Int {
        var v = 0, xx = x, yy = y
        for _ in 0..<3 {
            v = v * 4 + base2[yy & 1][xx & 1]
            xx >>= 1; yy >>= 1
        }
        return v
    }
    for y in 0..<8 { for x in 0..<8 { m[y][x] = (Double(value(x, y)) / 64.0) - 0.5 } }
    return m
}()

@inline(__always) func quantizePixel(_ px: [UInt8], _ i: Int) -> UInt8 {
    let y = i / W, x = i % W
    let o = bayer[y & 7][x & 7] * ditherStrength
    let r = min(255, max(0, Int((Double(px[i*3]) + o).rounded())))
    let g = min(255, max(0, Int((Double(px[i*3+1]) + o).rounded())))
    let b = min(255, max(0, Int((Double(px[i*3+2]) + o).rounded())))
    return nearest(r, g, b)
}

func quantize(_ px: [UInt8]) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: W * H)
    for i in 0..<(W * H) { out[i] = quantizePixel(px, i) }
    return out
}

// Screen captures carry ±1-2 LSB temporal noise from the compositor's
// dithering; without a threshold it flips palette indices all over the
// static background and bloats every inter-frame diff. A pixel only
// counts as changed when it moves more than NOISE_T away from the last
// EMITTED value (bounded error, no drift accumulation).
let noiseT = 6

// MARK: GIF writing

var gif = Data()
func u16(_ v: Int) { gif.append(UInt8(v & 0xFF)); gif.append(UInt8((v >> 8) & 0xFF)) }

gif.append(contentsOf: Array("GIF89a".utf8))
u16(W); u16(H)
gif.append(0xF7)  // GCT present, 8 bits, 256 entries
gif.append(0)     // background
gif.append(0)     // aspect
for c in palette { gif.append(c.0); gif.append(c.1); gif.append(c.2) }
gif.append(contentsOf: [0, 0, 0])  // index 255 (transparent slot)

// NETSCAPE loop forever
gif.append(contentsOf: [0x21, 0xFF, 0x0B])
gif.append(contentsOf: Array("NETSCAPE2.0".utf8))
gif.append(contentsOf: [0x03, 0x01, 0x00, 0x00, 0x00])

// LZW per gifenc.c (lecram): bump code size when the next assigned code
// hits 1<<codeSize, emit clear when the table is full at 4096
func lzw(_ indices: ArraySlice<UInt8>) -> Data {
    let clear = 256, end = 257
    var codeSize = 9
    var nextCode = 258
    var dict = [UInt32: Int]()
    dict.reserveCapacity(4096)
    var out = Data()
    var bitBuf: UInt32 = 0, bitCnt = 0
    func emit(_ code: Int) {
        bitBuf |= UInt32(code) << bitCnt
        bitCnt += codeSize
        while bitCnt >= 8 {
            out.append(UInt8(bitBuf & 0xFF))
            bitBuf >>= 8; bitCnt -= 8
        }
    }
    emit(clear)
    var it = indices.makeIterator()
    guard let f = it.next() else {
        emit(end)
        if bitCnt > 0 { out.append(UInt8(bitBuf & 0xFF)) }
        return out
    }
    var prefix = Int(f)
    while let sym = it.next() {
        let s = Int(sym)
        let key = UInt32(prefix) << 8 | UInt32(s)
        if let code = dict[key] {
            prefix = code
            continue
        }
        emit(prefix)
        if nextCode < 4096 {
            if nextCode == (1 << codeSize) { codeSize += 1 }
            dict[key] = nextCode
            nextCode += 1
        } else {
            emit(clear)
            dict.removeAll(keepingCapacity: true)
            codeSize = 9
            nextCode = 258
        }
        prefix = s
    }
    emit(prefix)
    emit(end)
    if bitCnt > 0 { out.append(UInt8(bitBuf & 0xFF)) }
    return out
}

func writeFrame(_ indices: [UInt8], rect: (x: Int, y: Int, w: Int, h: Int), transparent: Bool) {
    // graphic control extension
    gif.append(contentsOf: [0x21, 0xF9, 0x04])
    gif.append(UInt8(0x04 | (transparent ? 0x01 : 0x00)))  // disposal=1 (do not dispose)
    u16(delayCS)
    gif.append(transparent ? 255 : 0)
    gif.append(0)
    // image descriptor
    gif.append(0x2C)
    u16(rect.x); u16(rect.y); u16(rect.w); u16(rect.h)
    gif.append(0)  // no local color table
    gif.append(8)  // LZW min code size
    let data = lzw(indices[...])
    var off = 0
    while off < data.count {
        let n = min(255, data.count - off)
        gif.append(UInt8(n))
        gif.append(data.subdata(in: off..<(off + n)))
        off += n
    }
    gif.append(0)
}

var refSrc = [UInt8]()   // source RGB of the last emitted state per pixel
var prevIdx = [UInt8]()  // palette index currently on the decoder's canvas
for (fi, f) in files.enumerated() {
    let fr = fi == 0 ? first : loadRGB(framesDir + "/" + f)
    if fi == 0 {
        prevIdx = quantize(fr.px)
        refSrc = fr.px
        writeFrame(prevIdx, rect: (0, 0, W, H), transparent: false)
    } else {
        var minX = W, minY = H, maxX = -1, maxY = -1
        var changed = [Int]()
        for i in 0..<(W * H) {
            let dr = abs(Int(fr.px[i*3]) - Int(refSrc[i*3]))
            let dg = abs(Int(fr.px[i*3+1]) - Int(refSrc[i*3+1]))
            let db = abs(Int(fr.px[i*3+2]) - Int(refSrc[i*3+2]))
            if max(dr, max(dg, db)) <= noiseT { continue }
            refSrc[i*3] = fr.px[i*3]
            refSrc[i*3+1] = fr.px[i*3+1]
            refSrc[i*3+2] = fr.px[i*3+2]
            let idx = quantizePixel(fr.px, i)
            if idx == prevIdx[i] { continue }
            prevIdx[i] = idx
            changed.append(i)
            let x = i % W, y = i / W
            if x < minX { minX = x }
            if x > maxX { maxX = x }
            if y < minY { minY = y }
            if y > maxY { maxY = y }
        }
        if maxX < 0 {
            // unchanged frame: 1x1 transparent pixel keeps the timing
            writeFrame([255], rect: (0, 0, 1, 1), transparent: true)
        } else {
            let rw = maxX - minX + 1, rh = maxY - minY + 1
            var sub = [UInt8](repeating: 255, count: rw * rh)
            for i in changed {
                let x = i % W - minX, y = i / W - minY
                sub[y * rw + x] = prevIdx[i]
            }
            writeFrame(sub, rect: (minX, minY, rw, rh), transparent: true)
        }
    }
    if fi % 40 == 0 { print("encoded \(fi + 1)/\(files.count)") }
}

gif.append(0x3B)
try gif.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath): \(gif.count) bytes (\(String(format: "%.1f", Double(gif.count) / 1e6)) MB)")
