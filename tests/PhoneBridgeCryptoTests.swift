import Cocoa
import CryptoKit

// The audit tests do not create windows, request permissions, or send input.
@MainActor final class PhonePrompt {
    func activate() {}
    func present(title: String, detail: String, primary: String, secureInput: Bool, cancel: Bool = true, keyboardOnly: Bool = false) async -> String? { nil }
}
@main struct PhoneBridgeTests {
    static let label = CGRect(x: 120, y: 320, width: 410, height: 30)
    static func fixture(filled: Set<Int> = [], count: Int = 4, light: Bool = false,
                        centers: [CGFloat]? = nil, contrast: Double = 1) -> CGImage {
        let width = 650, height = 1000
        let background: UInt8 = light ? 255 : 0
        let foreground = UInt8(light ? (255 * (1 - contrast)).rounded() : (255 * contrast).rounded())
        var pixels = [UInt8](repeating: background, count: width * height * 4)
        for i in 0..<(width * height) { pixels[i * 4 + 3] = 255 }
        let xs = centers ?? (0..<count).map { CGFloat(235 + $0 * 60) }
        for (index, cx) in xs.enumerated() {
            for y in 395...425 { for x in Int(cx - 15)...Int(cx + 15) {
                let distance = hypot(CGFloat(x) - cx, CGFloat(y) - 410)
                if (filled.contains(index) && distance <= 13) || (!filled.contains(index) && distance >= 11 && distance <= 13) {
                    let offset = (y * width + x) * 4
                    pixels[offset] = foreground; pixels[offset+1] = foreground; pixels[offset+2] = foreground
                }
            } }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
    static func textFixture(settingsHeader: Bool = true, light: Bool = false, failedAttempt: Bool = false) -> CGImage {
        let image = fixture(light: light)
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 28), .foregroundColor: light ? NSColor.black : NSColor.white]
        if settingsHeader { ("Enter Passcode" as NSString).draw(at: CGPoint(x: 120, y: 890), withAttributes: attributes) }
        ("Enter Screen Time Passcode" as NSString).draw(at: CGPoint(x: 120, y: 650), withAttributes: attributes)
        if failedAttempt { ("1 Failed Passcode Attempt" as NSString).draw(at: CGPoint(x: 120, y: 480), withAttributes: attributes) }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()!
    }
    @MainActor static func main() throws {
        let password = "dummy-test-password-never-used-for-real"
        let first = try PhoneBridge.seal("1234", password: password)
        let second = try PhoneBridge.seal("1234", password: password)
        let opened = try PhoneBridge.open(first, password: password)
        precondition(opened == "1234")
        precondition(first.salt != second.salt && first.sealed != second.sealed)
        var rejected = false
        do { _ = try PhoneBridge.open(first, password: "wrong-password") } catch { rejected = true }
        precondition(rejected)
        var tampered = first.sealed; tampered[0] ^= 1
        rejected = false
        do { _ = try PhoneBridge.open(PhoneBridge.Vault(salt: first.salt, sealed: tampered), password: password) } catch { rejected = true }
        precondition(rejected)
        print("PASS encryption: round trip, randomized ciphertext, wrong password, tampering")
        let unlockText = ["enter passcode", "enter screen time passcode"]
        precondition(PhoneBridge.isUnlockScreen(unlockText))
        precondition(PhoneBridge.isUnlockScreen(unlockText + ["1 failed passcode attempt"]))
        precondition(!PhoneBridge.isUnlockScreen(unlockText + ["try again in 1 minute"]))
        precondition(!PhoneBridge.isUnlockScreen(unlockText + ["enter new passcode"]))
        precondition(!PhoneBridge.isUnlockScreen(["enter passcode"]))
        let appUnlockText = ["enter screen time passcode"]
        precondition(PhoneBridge.isUnlockScreen(appUnlockText))
        precondition(PhoneBridge.isUnlockScreen(appUnlockText + ["1 failed passcode attempt"]))
        precondition(!PhoneBridge.isUnlockScreen(appUnlockText + ["try again in 1 minute"]))
        precondition(!PhoneBridge.isUnlockScreen(appUnlockText + ["enter new passcode"]))
        precondition(!PhoneBridge.isUnlockScreen(["enter iphone passcode"]))
        precondition(PhoneBridge.passcodeSlots(in: fixture(), below: label, expectedFilled: 0) != nil)
        precondition(PhoneBridge.passcodeSlots(in: fixture(light: true), below: label, expectedFilled: 0) != nil)
        for count in 1...3 {
            precondition(PhoneBridge.passcodeSlots(in: fixture(filled: Set(0..<count)), below: label, expectedFilled: count) != nil)
            precondition(PhoneBridge.passcodeSlots(in: fixture(filled: Set(0..<count)), below: label, expectedFilled: 0) == nil)
        }
        precondition(PhoneBridge.passcodeSlots(in: fixture(filled: [1]), below: label, expectedFilled: 1) == nil)
        precondition(PhoneBridge.passcodeSlots(in: fixture(count: 3), below: label, expectedFilled: 0) == nil)
        precondition(PhoneBridge.passcodeSlots(in: fixture(count: 5, centers: [205, 265, 325, 385, 445]), below: label, expectedFilled: 0) == nil)
        precondition(PhoneBridge.passcodeSlots(in: fixture(centers: [225, 260, 370, 435]), below: label, expectedFilled: 0) == nil)
        precondition(PhoneBridge.passcodeSlots(in: fixture(contrast: 0.05), below: label, expectedFilled: 0) == nil)
        precondition(PhoneBridge.passcodeSlots(in: fixture(), below: label, expectedFilled: 4) == nil)
        print("PASS screen state: light/dark empty slots, fill progression, nonempty/ambiguous/low-contrast rejection")
        let observations = [
            PhoneBridge.RecognizedText(text: "enter passcode", confidence: 1, boundingBox: .zero),
            PhoneBridge.RecognizedText(text: "enter screen time passcode", confidence: 1,
                boundingBox: CGRect(x: label.minX / 650, y: 1 - label.maxY / 1000, width: label.width / 650, height: label.height / 1000))
        ]
        let engineError = NSError(domain: "TextRecognition.CRImageReaderError", code: 1)
        let appObservations = observations.filter { $0.text != "enter passcode" } + [
            .init(text: "1 failed passcode attempt", confidence: 1, boundingBox: .zero)
        ]
        for filled in 0...3 {
            for fallback in [false, true] {
                let appState = try PhoneBridge.analyzeFrame(fixture(filled: Set(0..<filled)), expectedFilled: filled) { _, mode in
                    if fallback && mode == .standard { throw engineError }
                    return appObservations
                }
                precondition(appState.centers.count == 4)
            }
        }
        var modes: [PhoneBridge.TextRecognitionMode] = []
        let recovered = try PhoneBridge.analyzeFrame(fixture(), expectedFilled: 0) { image, mode in
            modes.append(mode)
            precondition(image.bitsPerComponent == 8 && image.bitsPerPixel == 32 && image.width == 650 && image.height == 1000)
            if mode == .standard { throw engineError }
            return observations
        }
        precondition(modes == [.standard, .compatibility] && recovered.centers.count == 4)
        for light in [false, true] { for count in 0...3 {
            let image = try PhoneBridge.recognitionImage(fixture(filled: Set(0..<count), light: light))
            precondition(PhoneBridge.passcodeSlots(in: image, below: label, expectedFilled: count) != nil)
        } }
        let wideContext = CGContext(data: nil, width: 650, height: 1000, bitsPerComponent: 16, bytesPerRow: 650 * 8,
            space: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)!
        wideContext.draw(fixture(), in: CGRect(x: 0, y: 0, width: 650, height: 1000))
        let normalizedWide = try PhoneBridge.recognitionImage(wideContext.makeImage()!)
        precondition(normalizedWide.bitsPerComponent == 8 && normalizedWide.bitsPerPixel == 32)
        precondition(PhoneBridge.passcodeSlots(in: normalizedWide, below: label, expectedFilled: 0) != nil)
        modes = []
        do {
            _ = try PhoneBridge.analyzeFrame(fixture(filled: [0]), expectedFilled: 0) { _, mode in
                modes.append(mode)
                if mode == .standard { throw engineError }
                return observations
            }
            preconditionFailure("compatibility recognizer bypassed slot validation")
        } catch { precondition(modes == [.standard, .compatibility]) }
        modes = []
        do {
            _ = try PhoneBridge.analyzeFrame(fixture(), expectedFilled: 0) { _, mode in modes.append(mode); throw engineError }
            preconditionFailure("both recognition failures accepted")
        } catch {
            precondition(modes == [.standard, .compatibility])
            precondition((error as NSError).domain == "HarmonyPhone" && error.localizedDescription.contains("clear any filled dots"))
            precondition(!error.localizedDescription.contains("CRImageReader"))
        }
        // A successful OCR result that fails screen/slot checks must never cause a
        // compatibility retry that could reinterpret an unsafe screen as acceptable.
        for unsafe in [[], observations + [.init(text: "try again in 1 minute", confidence: 1, boundingBox: .zero)]] {
            modes = []
            do {
                _ = try PhoneBridge.analyzeFrame(fixture(), expectedFilled: 0) { _, mode in modes.append(mode); return unsafe }
                preconditionFailure("unsafe screen accepted")
            } catch { precondition(modes == [.standard]) }
        }
        modes = []
        do {
            _ = try PhoneBridge.analyzeFrame(fixture(), expectedFilled: 0) { _, mode in modes.append(mode); throw CancellationError() }
            preconditionFailure("cancellation ignored")
        } catch is CancellationError { precondition(modes == [.standard]) }
        print("PASS OCR recovery: normalized pixels/coordinates, one engine-only fallback, readable failure, unsafe-screen rejection, cancellation")
        for settingsHeader in [false, true] { for light in [false, true] {
            let textImage = textFixture(settingsHeader: settingsHeader, light: light, failedAttempt: true)
            for mode in [PhoneBridge.TextRecognitionMode.standard, .compatibility] {
                let result = try PhoneBridge.analyzeFrame(textImage, expectedFilled: 0) { image, _ in try PhoneBridge.recognizeText(in: image, mode: mode) }
                precondition(result.centers.count == 4)
            }
        } }
        print("PASS actual Vision: Settings/per-app prompts, failed-attempt banner, light/dark and both recognition paths")
        // Optional supplied screenshot regression: reads an image only; never
        // captures the desktop, authenticates, or sends keyboard input.
        if CommandLine.arguments.count == 2 {
            let url = URL(fileURLWithPath: CommandLine.arguments[1])
            let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
            for mode in [PhoneBridge.TextRecognitionMode.standard, .compatibility] {
                let result = try PhoneBridge.analyzeFrame(image, expectedFilled: 0) { image, _ in try PhoneBridge.recognizeText(in: image, mode: mode) }
                precondition(result.centers.count == 4)
            }
            print("PASS supplied screenshot: both recognition paths verified the empty passcode prompt")
        }
        precondition((48...57).map { PhoneBridge.keyCode(for: UInt8($0))! } == [29,18,19,20,21,23,22,26,28,25])
        precondition(PhoneBridge.keyCode(for: 65) == nil)
        let bridge = PhoneBridge(unlockDigest: "unused")
        try bridge.checkAuthorization()
        bridge.isEnabled = { false }
        rejected = false
        do { try bridge.checkAuthorization() } catch { rejected = true }
        precondition(rejected)
        print("PASS input mapping and disabled-session authorization")
        let config = AppConfiguration(unlockDigest: String(repeating: "a", count: 64), approvedPaths: [])
        let restored = try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(config))
        precondition(restored.version == 1 && restored.unlockDigest == config.unlockDigest)
        precondition(restored.approvedIDs == ["local.harmony.focus", "com.apple.finder", "com.apple.systempreferences"])
        let moved = AppConfiguration(unlockDigest: config.unlockDigest, approvedPaths: ["/missing/app.app"], approvedBundleIDs: ["com.example.approved"])
        precondition(moved.approvedIDs.contains("com.example.approved"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harmony-install-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.app")
        let destination = root.appendingPathComponent("installed/Harmony.app")
        let lockDirectory = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: source.appendingPathComponent("marker"))
        try Data("old".utf8).write(to: destination.appendingPathComponent("marker"))
        var heldLock: HarmonyInstanceLock? = try HarmonyInstanceLock(directory: lockDirectory)
        precondition(heldLock!.acquire())
        var refused = false
        do { _ = try AppSetup.installApp(from: source, to: destination, lockDirectory: lockDirectory) }
        catch { refused = true }
        let unchanged = try Data(contentsOf: destination.appendingPathComponent("marker"))
        precondition(refused && unchanged == Data("old".utf8))
        heldLock = nil
        let backup = try AppSetup.installApp(from: source, to: destination, lockDirectory: lockDirectory)
        let installed = try Data(contentsOf: destination.appendingPathComponent("marker"))
        let previous = try Data(contentsOf: backup!.appendingPathComponent("marker"))
        precondition(installed == Data("new".utf8))
        precondition(previous == Data("old".utf8))
        print("PASS recipient setup: stable allowed IDs and locked, recoverable install")
    }
}
