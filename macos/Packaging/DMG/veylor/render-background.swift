// Renders the background of Veylor's DMG window in the neon look: true
// black, the lit VEYLOR wordmark, "Drag Veylor to Applications" and a lit
// arrow from the app to the Applications folder. It writes background.png
// (600×400) and background@2x.png (1200×800, 144 dpi) beside this file;
// dmgbuild joins the two into one HiDPI TIFF. The icon centres match
// scripts/veylor-macos-release/dmg-settings.py.
//
// Run from the repository root after changing the design:
//   xcrun swift macos/Packaging/DMG/veylor/render-background.swift
import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let canvasWidth: CGFloat = 600
let canvasHeight: CGFloat = 400

// Finder centres the icons here (dmg-settings.py's icon_locations).
let iconY: CGFloat = 240
let appIconX: CGFloat = 160
let applicationsIconX: CGFloat = 440

// NeonPrimitives in lib/src/core/theme/primitives.dart.
let neonRed = rgb(0xFF2E3E)
let neonRedCore = rgb(0xFFE4E7)
let captionColor = rgb(0xCDCDD4) // n700Dark

func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
  CGColor(
    srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
    green: CGFloat((hex >> 8) & 0xFF) / 255,
    blue: CGFloat(hex & 0xFF) / 255,
    alpha: alpha
  )
}

func lerp(_ a: CGColor, _ b: CGColor, _ t: CGFloat) -> CGColor {
  let x = a.components!, y = b.components!
  return CGColor(
    srgbRed: x[0] + (y[0] - x[0]) * t,
    green: x[1] + (y[1] - x[1]) * t,
    blue: x[2] + (y[2] - x[2]) * t,
    alpha: 1
  )
}

// VeylorWordmarkPainter's letters (lib/src/core/widgets/mobile/
// veylor_wordmark.dart): six 10-unit letters, 4.5 units apart, 14 tall.
let letters: [[[CGPoint]]] = [
  [[p(0, 0), p(4, 14), p(6, 14), p(10, 0)]],
  [[p(10, 0), p(0, 0), p(0, 14), p(10, 14)], [p(2.6, 7), p(8.5, 7)]],
  [[p(0, 0), p(5, 7), p(10, 0)], [p(5, 7), p(5, 14)]],
  [[p(0, 0), p(0, 14), p(10, 14)]],
  [[p(3, 0), p(10, 0), p(10, 11), p(7, 14), p(0, 14), p(0, 3), p(3, 0)]],
  [
    [p(0, 14), p(0, 0), p(7.5, 0), p(10, 2.5), p(10, 4.5), p(7.5, 7), p(0, 7)],
    [p(6.5, 7), p(10, 10.5), p(10, 14)],
  ],
]

func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

/// The wordmark centred on [center], [artWidth] points wide, with the tube
/// width the painter gives that size.
func wordmark(center: CGPoint, artWidth: CGFloat) -> (path: CGPath, width: CGFloat) {
  let scale = artWidth / 82.5
  let left = center.x - artWidth / 2
  let top = center.y - 14 * scale / 2
  let path = CGMutablePath()
  for (index, strokes) in letters.enumerated() {
    let x0 = left + CGFloat(index) * 14.5 * scale
    for stroke in strokes {
      let points = stroke.map { CGPoint(x: x0 + $0.x * scale, y: top + $0.y * scale) }
      path.move(to: points[0])
      for point in points.dropFirst() { path.addLine(to: point) }
      if stroke.count > 2 && stroke.first == stroke.last { path.closeSubpath() }
    }
  }
  return (path, max(1, scale * 0.95))
}

/// A straight arrow with a 45° head, pointing right.
func arrow(from startX: CGFloat, to endX: CGFloat, y: CGFloat, head: CGFloat) -> CGPath {
  let path = CGMutablePath()
  path.move(to: CGPoint(x: startX, y: y))
  path.addLine(to: CGPoint(x: endX, y: y))
  path.move(to: CGPoint(x: endX - head, y: y - head))
  path.addLine(to: CGPoint(x: endX, y: y))
  path.addLine(to: CGPoint(x: endX - head, y: y + head))
  return path
}

final class Canvas {
  let scale: CGFloat
  let pixelWidth: Int
  let pixelHeight: Int
  let ciContext = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
  private(set) var image: CIImage

  init(scale: CGFloat) {
    self.scale = scale
    pixelWidth = Int(canvasWidth * scale)
    pixelHeight = Int(canvasHeight * scale)
    image = CIImage(color: CIColor(red: 0, green: 0, blue: 0))
      .cropped(to: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
  }

  var extent: CGRect { CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight) }

  /// Draws into a transparent layer in points with a top-left origin, blurs
  /// it by [sigma] points if asked, and composites it over the canvas.
  func layer(blurSigma sigma: CGFloat = 0, _ draw: (CGContext) -> Void) {
    let context = CGContext(
      data: nil,
      width: pixelWidth,
      height: pixelHeight,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.translateBy(x: 0, y: CGFloat(pixelHeight))
    context.scaleBy(x: scale, y: -scale)
    context.setShouldAntialias(true)
    draw(context)
    var layer = CIImage(cgImage: context.makeImage()!)
    if sigma > 0 {
      layer = layer.clampedToExtent()
        .applyingGaussianBlur(sigma: Double(sigma * scale))
        .cropped(to: extent)
    }
    image = layer.composited(over: image)
  }

  func write(to url: URL) {
    let cgImage = ciContext.createCGImage(
      image,
      from: extent,
      format: .RGBA8,
      colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
    )!
    // Drop the alpha channel: the background is opaque.
    let opaque = CGContext(
      data: nil,
      width: pixelWidth,
      height: pixelHeight,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    opaque.draw(cgImage, in: extent)
    let destination = CGImageDestinationCreateWithURL(
      url as CFURL,
      UTType.png.identifier as CFString,
      1,
      nil
    )!
    let dpi = 72 * scale
    let properties = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary
    CGImageDestinationAddImage(destination, opaque.makeImage()!, properties)
    guard CGImageDestinationFinalize(destination) else {
      fatalError("Could not write \(url.path)")
    }
  }
}

/// Neon.strokeTube (lib/src/core/theme/neon.dart): a wide faint halo, a
/// tighter glow and the near-white core, with square caps and mitred joins.
func strokeTube(_ canvas: Canvas, _ path: CGPath, width: CGFloat, intensity k: CGFloat) {
  func stroke(_ context: CGContext, lineWidth: CGFloat, color: CGColor) {
    context.addPath(path)
    context.setLineWidth(lineWidth)
    context.setLineCap(.square)
    context.setLineJoin(.miter)
    context.setStrokeColor(color)
    context.strokePath()
  }
  canvas.layer(blurSigma: 10) { stroke($0, lineWidth: width * 5, color: neonRed.copy(alpha: 0.28 * k)!) }
  canvas.layer(blurSigma: 3) { stroke($0, lineWidth: width * 2.2, color: neonRed.copy(alpha: 0.75 * k)!) }
  canvas.layer { stroke($0, lineWidth: width, color: lerp(neonRed, neonRedCore, 0.75).copy(alpha: k)!) }
}

func drawCaption(_ canvas: Canvas, _ text: String, fontURL: URL, size: CGFloat, baselineY: CGFloat) {
  guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(fontURL as CFURL) as? [CTFontDescriptor],
        let descriptor = descriptors.first else {
    fatalError("Could not load \(fontURL.path)")
  }
  let font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
  let attributes: [NSAttributedString.Key: Any] = [
    NSAttributedString.Key(kCTFontAttributeName as String): font,
    NSAttributedString.Key(kCTForegroundColorAttributeName as String): captionColor,
    NSAttributedString.Key(kCTKernAttributeName as String): size * 0.02,
  ]
  let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
  let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
  canvas.layer { context in
    context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    context.textPosition = CGPoint(x: (canvasWidth - lineWidth) / 2, y: baselineY)
    CTLineDraw(line, context)
  }
}

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let root = here.appendingPathComponent("../../../..").standardizedFileURL
let gothamLight = root.appendingPathComponent("assets/fonts/Gotham-Light.otf")

for (scale, name) in [(CGFloat(1), "background.png"), (CGFloat(2), "background@2x.png")] {
  let canvas = Canvas(scale: scale)
  let mark = wordmark(center: CGPoint(x: canvasWidth / 2, y: 82), artWidth: 172)
  strokeTube(canvas, mark.path, width: mark.width, intensity: 0.75)
  drawCaption(canvas, "Drag Veylor to Applications", fontURL: gothamLight, size: 17, baselineY: 146)
  let arrowPath = arrow(from: appIconX + 76, to: applicationsIconX - 76, y: iconY, head: 8)
  strokeTube(canvas, arrowPath, width: 1.4, intensity: 0.6)
  let url = here.appendingPathComponent(name)
  canvas.write(to: url)
  print("Wrote \(url.path)")
}
