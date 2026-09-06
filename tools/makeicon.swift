// makeicon <source.png> <out.png>
// Finds the artwork on a black canvas, and re-lays it on a transparent 1024 canvas with the
// macOS icon inset (824 px) and corner radius, so Finder gets proper rounded corners.
import AppKit

let args = CommandLine.arguments
guard args.count == 3,
      let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    print("usage: makeicon <source.png> <out.png>"); exit(1)
}

// Bounding box of everything brighter than near-black.
let w = image.width, h = image.height
let ctx0 = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                     space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx0.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
let px = ctx0.data!.assumingMemoryBound(to: UInt8.self)
var minX = w, minY = h, maxX = 0, maxY = 0
for y in 0..<h { for x in 0..<w {
    let i = (y * w + x) * 4
    if Int(px[i]) + Int(px[i + 1]) + Int(px[i + 2]) > 60 {
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
    }
}}
let side = max(maxX - minX, maxY - minY) + 1
let crop = image.cropping(to: CGRect(x: minX, y: h - 1 - maxY, width: side, height: side))!   // CG y is flipped vs. our scan
print("artwork \(side)x\(side) at (\(minX), \(minY)) in \(w)x\(h)")

let size = 1024, inset = 100, art = 824
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let rect = CGRect(x: inset, y: inset, width: art, height: art)
ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil))
ctx.clip()
ctx.interpolationQuality = .high
ctx.draw(crop, in: rect)
let out = ctx.makeImage()!
try! NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("wrote \(args[2])")
