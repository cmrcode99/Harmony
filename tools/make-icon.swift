// Generate the app's own icon without external artwork or third-party tools.
import AppKit
import Foundation

func renderIcon(size: Int) throws -> Data {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let transform = NSAffineTransform()
    transform.scale(by: CGFloat(size) / 1024)
    transform.concat()
    let background = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 180, yRadius: 180)
    let top = NSColor(srgbRed: 23/255, green: 59/255, blue: 70/255, alpha: 1)
    let bottom = NSColor(srgbRed: 9/255, green: 21/255, blue: 31/255, alpha: 1)
    NSGradient(starting: top, ending: bottom)!.draw(in: background, angle: -45)
    let pale = NSColor(srgbRed: 220/255, green: 248/255, blue: 244/255, alpha: 1)
    let eye = NSBezierPath()
    eye.move(to: NSPoint(x: 244, y: 512))
    eye.curve(to: NSPoint(x: 780, y: 512), controlPoint1: NSPoint(x: 365, y: 680), controlPoint2: NSPoint(x: 659, y: 680))
    eye.curve(to: NSPoint(x: 244, y: 512), controlPoint1: NSPoint(x: 659, y: 344), controlPoint2: NSPoint(x: 365, y: 344))
    eye.close()
    eye.lineWidth = 42
    eye.lineJoinStyle = .round
    pale.setStroke()
    eye.stroke()
    NSColor(srgbRed: 45/255, green: 212/255, blue: 191/255, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 420, y: 420, width: 184, height: 184)).fill()
    pale.setFill()
    NSBezierPath(ovalIn: NSRect(x: 516, y: 518, width: 44, height: 44)).fill()
    image.unlockFocus()
    var proposed = NSRect(origin: .zero, size: image.size)
    guard let cgImage = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil),
          let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return data
}

func run() throws {
    guard CommandLine.arguments.count == 2 else {
        throw NSError(domain: "HarmonyIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Usage: swift tools/make-icon.swift OUTPUT.icns"])
    }
    let output = URL(fileURLWithPath: CommandLine.arguments[1])
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("harmony-icon-" + UUID().uuidString)
    let iconset = temporary.appendingPathComponent("Harmony.iconset")
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    for size in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let suffix = scale == 2 ? "@2x" : ""
            try renderIcon(size: size * scale).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
        }
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["-c", "icns", iconset.path, "-o", output.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
}

do { try run() }
catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
