import Cocoa
import CryptoKit
import ApplicationServices
import ScreenCaptureKit
import Vision
import CoreML

@MainActor final class PhoneBridge {
    let unlockDigest: String
    var onAccess: ((Bool) -> Void)?
    var isEnabled: () -> Bool = { true }
    private var task: Task<Void, Never>?
    func cancel() { task?.cancel() }
    func checkAuthorization() throws {
        try Task.checkCancellation()
        guard isEnabled() else { throw bridgeError("Harmony is no longer enabled. No further phone input will be sent.") }
    }
    private var busy = false
    var isBusy: Bool { busy }
    func activatePrompt() { prompt.activate() }
    private let mirrorID = "com.apple.ScreenContinuity"
    private var vaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Harmony Focus/phone-vault.json")
    }
    struct Vault: Codable {
        let salt: Data
        let sealed: Data
        // Allows an encrypted vault to survive a product-identifier migration.
        // This is public KDF metadata, never the password or phone code.
        let keyContext: Data?
        init(salt: Data, sealed: Data, keyContext: Data? = nil) {
            self.salt = salt; self.sealed = sealed; self.keyContext = keyContext
        }
    }
    init(unlockDigest: String) { self.unlockDigest = unlockDigest }
    private let prompt = PhonePrompt()
    private func message(_ title: String, _ detail: String) async {
        guard !Task.isCancelled, isEnabled() else { return }
        UserDefaults.standard.set(title, forKey: "phoneStatus")
        UserDefaults.standard.set(detail, forKey: "phoneStatusDetail")
        _ = await prompt.present(title: title, detail: detail, primary: "OK", secureInput: false, cancel: false)
    }
    private func ask(_ title: String, _ detail: String, button: String) async -> String? {
        guard !Task.isCancelled, isEnabled() else { return nil }
        UserDefaults.standard.set(title, forKey: "phoneStatus")
        UserDefaults.standard.set(detail, forKey: "phoneStatusDetail")
        return await prompt.present(title: title, detail: detail, primary: button, secureInput: true, keyboardOnly: true)
    }
    private static func key(_ password: String, salt: Data, context: Data? = nil) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(password.utf8)), salt: salt,
                             info: context ?? Data("local.harmony.phone.v1".utf8), outputByteCount: 32)
    }
    static func seal(_ pin: String, password: String, keyContext: Data? = nil) throws -> Vault {
        guard keyContext == nil || keyContext!.count <= 128 else { throw NSError(domain: "Harmony", code: 3) }
        let salt = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let box = try AES.GCM.seal(Data(pin.utf8), using: key(password, salt: salt, context: keyContext))
        guard let combined = box.combined else { throw NSError(domain: "Harmony", code: 1) }
        return Vault(salt: salt, sealed: combined, keyContext: keyContext)
    }
    static func open(_ vault: Vault, password: String) throws -> String {
        guard vault.keyContext == nil || vault.keyContext!.count <= 128 else { throw NSError(domain: "Harmony", code: 3) }
        let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: vault.sealed), using: key(password, salt: vault.salt, context: vault.keyContext))
        guard let pin = String(data: plaintext, encoding: .utf8), pin.count == 4,
              pin.utf8.allSatisfy({ (48...57).contains($0) }) else { throw NSError(domain: "Harmony", code: 2) }
        return pin
    }
    func run() {
        guard !busy else { return }
        busy = true
        task = Task { @MainActor in
            await self.runFlow()
            self.finish()
        }
    }
    private func runFlow() async {
        guard #available(macOS 14.0, *) else {
            await message("Phone helper unavailable", "iPhone Mirroring requires a supported Mac and macOS version.")
            return
        }
        do { try checkAuthorization() }
        catch { await message("Phone entry unavailable", error.localizedDescription); return }
        guard AXIsProcessTrusted() else {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            await message("Allow control access for Harmony", "Enable Harmony in Device Control and Data Access, then try again.")
            return
        }
        guard let mirror = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == mirrorID }) else {
            await message("Open iPhone Mirroring first", "Navigate to an empty Enter Screen Time Passcode prompt, then run harmony phone.")
            return
        }
        onAccess?(true)
        do { try await revealMirror(mirror, requireFocus: false) }
        catch { await message("Open iPhone Mirroring", error.localizedDescription); return }
        let detail = "Enter your 50-character Harmony password. The phone code is typed only into the Screen Time passcode prompt."
        guard let password = await ask("Unlock phone entry", detail, button: "Verify and type") else { return }
        let hash = SHA256.hash(data: Data(password.utf8)).map { String(format: "%02x", $0) }.joined()
        let expected = unlockDigest
        guard hash == expected else {
            UserDefaults.standard.set("Password did not match; no input sent", forKey: "phoneStatus")
            return
        }
        let pin: String
        do {
            try checkAuthorization()
            guard FileManager.default.fileExists(atPath: vaultURL.path) else {
                await message("Phone helper not set up", "Finish your current session, then ask your agent to run harmony setup phone. You can keep using Harmony on your Mac without the phone helper. No input was sent.")
                return
            }
            pin = try Self.open(JSONDecoder().decode(Vault.self, from: PrivateSettingsStore.read(from: vaultURL)), password: password)
        } catch {
            await message("Could not unlock encrypted phone code", "No input was sent. The encrypted record may belong to an older password."); return
        }
        do {
            try checkAuthorization()
            try await revealMirror(mirror)
            try checkAuthorization()
            try await self.typeIfScreenTime(pin, mirror: mirror)
            UserDefaults.standard.set(true, forKey: "screenCaptureGranted")
            UserDefaults.standard.set("Phone code entered; acceptance not verified", forKey: "phoneStatus")
        } catch {
            await self.message("Phone entry stopped", error.localizedDescription)
        }
    }
    private func revealMirror(_ mirror: NSRunningApplication, requireFocus: Bool = true) async throws {
        try checkAuthorization()
        mirror.unhide()
        var value: CFTypeRef?
        let app = AXUIElementCreateApplication(mirror.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.25)
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
           let windows = value as? [AXUIElement] {
            // Restore only the actual phone window, not incidental dialogs.
            for window in windows {
                AXUIElementSetMessagingTimeout(window, 0.25)
                var identifier: CFTypeRef?
                _ = AXUIElementCopyAttributeValue(window, kAXIdentifierAttribute as CFString, &identifier)
                guard identifier as? String == "iphone-mirroring-main" else { continue }
                _ = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            }
        }
        guard requireFocus else { return }
        if #available(macOS 14.0, *) { NSApp.yieldActivation(to: mirror) }
        _ = AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        _ = mirror.activate(options: [])
        // Wait only as long as activation actually needs. Two observations
        // allow the closed password panel's focus handoff to settle; capturePrompt
        // still validates the precise phone screen before any key is sent.
        let deadline = ProcessInfo.processInfo.systemUptime + 0.8
        var wasForeground = false
        repeat {
            try checkAuthorization()
            let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier == mirror.processIdentifier
            if foreground && wasForeground { return }
            wasForeground = foreground
            try await Task.sleep(nanoseconds: 50_000_000)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw bridgeError("Could not bring iPhone Mirroring to the front. Open its Screen Time passcode prompt and try again. No code was typed.")
    }
    private func finish() {
        task = nil
        busy = false
        onAccess?(false)
        // Password/PIN variables remain local to one invocation, never cached for another request.
    }
    struct SlotLayout: Sendable {
        let centers: [CGPoint]
        let diameter: CGFloat
    }
    private struct Raster {
        let width: Int
        let height: Int
        let pixels: [UInt8]
        init?(_ image: CGImage) {
            let width = image.width, height = image.height
            self.width = width; self.height = height
            guard width > 0, height > 0, width <= 5000, height <= 10000 else { return nil }
            var data = [UInt8](repeating: 0, count: width * height * 4)
            let rendered = data.withUnsafeMutableBytes { bytes -> Bool in
                guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard rendered else { return nil }
            pixels = data
        }
        func light(_ x: Int, _ y: Int) -> Double {
            let x = min(width - 1, max(0, x)), y = min(height - 1, max(0, y))
            let i = (y * width + x) * 4
            return (Double(pixels[i]) + Double(pixels[i + 1]) + Double(pixels[i + 2])) / 765
        }
    }
    /// Pixel-space bounds use the image's top-left origin. Reject ambiguity rather than guessing.
    nonisolated static func passcodeSlots(in image: CGImage, below label: CGRect, expectedFilled: Int) -> SlotLayout? {
        guard (0...3).contains(expectedFilled), let raster = Raster(image), label.height >= 8 else { return nil }
        let x0 = max(0, Int(label.midX - label.height * 5)), x1 = min(raster.width, Int(label.midX + label.height * 5))
        let y0 = max(0, Int(label.maxY + label.height * 0.4)), y1 = min(raster.height, Int(label.maxY + label.height * 4.2))
        guard x1 > x0, y1 > y0 else { return nil }
        let w = x1 - x0, h = y1 - y0
        var samples: [Double] = []
        for i in 0..<20 {
            let x = x0 + (w - 1) * i / 19
            samples.append(raster.light(x, y0)); samples.append(raster.light(x, y1 - 1))
        }
        samples.sort(); let background = samples[samples.count / 2]
        var mask = [Bool](repeating: false, count: w * h)
        for y in 0..<h { for x in 0..<w { mask[y * w + x] = abs(raster.light(x + x0, y + y0) - background) > 0.18 } }
        struct Circle { let center: CGPoint; let diameter: CGFloat; let filled: Bool }
        var circles: [Circle] = []
        for start in 0..<mask.count where mask[start] {
            mask[start] = false
            var queue = [start], cursor = 0
            var minX = start % w, maxX = minX, minY = start / w, maxY = minY
            while cursor < queue.count {
                let at = queue[cursor]; cursor += 1
                let x = at % w, y = at / w
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
                    let nx = x + dx, ny = y + dy
                    if nx >= 0 && nx < w && ny >= 0 && ny < h {
                        let index = ny * w + nx
                        if mask[index] { mask[index] = false; queue.append(index) }
                    }
                } }
            }
            let cw = CGFloat(maxX - minX + 1), ch = CGFloat(maxY - minY + 1)
            guard cw >= label.height * 0.35, ch >= label.height * 0.35,
                  cw <= label.height * 1.8, ch <= label.height * 1.8,
                  cw / ch > 0.75, cw / ch < 1.33 else { continue }
            let center = CGPoint(x: CGFloat(x0) + CGFloat(minX + maxX) / 2, y: CGFloat(y0) + CGFloat(minY + maxY) / 2)
            let radius = (cw + ch) / 4
            var edgeHits = 0
            for angle in 0..<32 {
                let theta = Double(angle) * 2 * Double.pi / 32
                var peak = 0.0
                for factor in stride(from: 0.70, through: 1.10, by: 0.05) {
                    let x = Int((center.x + radius * factor * cos(theta)).rounded())
                    let y = Int((center.y + radius * factor * sin(theta)).rounded())
                    peak = max(peak, abs(raster.light(x, y) - background))
                }
                if peak > 0.15 { edgeHits += 1 }
            }
            guard edgeHits >= 27 else { continue }
            var interior = 0.0, count = 0
            for dy in -2...2 { for dx in -2...2 {
                let x = Int((center.x + CGFloat(dx) * radius * 0.13).rounded())
                let y = Int((center.y + CGFloat(dy) * radius * 0.13).rounded())
                interior += abs(raster.light(x, y) - background); count += 1
            } }
            let contrast = interior / Double(count)
            guard contrast < 0.10 || contrast > 0.30 else { continue }
            circles.append(Circle(center: center, diameter: radius * 2, filled: contrast > 0.30))
        }
        var accepted: [SlotLayout] = []
        var checkedRows = Set<Int>()
        for seed in circles {
            let row = circles.filter { abs($0.center.y - seed.center.y) < seed.diameter * 0.35 }.sorted { $0.center.x < $1.center.x }
            guard row.count == 4 else { continue }
            let rowKey = Int(row[0].center.y.rounded())
            guard checkedRows.insert(rowKey).inserted else { continue }
            let diameters = row.map(\.diameter)
            guard let low = diameters.min(), let high = diameters.max(), high / low < 1.35 else { continue }
            let gaps = (1..<4).map { row[$0].center.x - row[$0 - 1].center.x }
            let meanGap = gaps.reduce(0, +) / 3
            guard meanGap > high * 1.5, meanGap < high * 4,
                  gaps.allSatisfy({ abs($0 - meanGap) < meanGap * 0.20 }),
                  abs((row[0].center.x + row[3].center.x) / 2 - label.midX) < label.height * 1.5,
                  row.enumerated().allSatisfy({ $0.element.filled == ($0.offset < expectedFilled) }) else { continue }
            accepted.append(SlotLayout(centers: row.map(\.center), diameter: (low + high) / 2))
        }
        return accepted.count == 1 ? accepted[0] : nil
    }
    /// Settings and per-app approvals share the Screen Time label and four
    /// indicators. The separate navigation heading is optional in per-app sheets.
    /// A previous-failure count is normal; a lockout or credential change is not.
    nonisolated static func isUnlockScreen(_ texts: [String]) -> Bool {
        guard texts.contains("enter screen time passcode") else { return false }
        return !texts.contains { text in
            ["incorrect", "new passcode", "re-enter", "try again", "try in", "minute", "unavailable", "disabled"].contains(where: text.contains)
        }
    }
    private struct CapturedPrompt {
        let windowID: CGWindowID
        let width: Int
        let height: Int
        let slots: SlotLayout
    }
    private func assertTarget(_ mirror: NSRunningApplication, windowID: CGWindowID) throws {
        guard !mirror.isTerminated, NSWorkspace.shared.frontmostApplication?.processIdentifier == mirror.processIdentifier else {
            throw bridgeError("iPhone Mirroring lost focus. Input stopped.")
        }
        guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]],
              let front = windows.first(where: {
                  guard ($0[kCGWindowOwnerPID as String] as? Int) == Int(mirror.processIdentifier),
                        let bounds = $0[kCGWindowBounds as String] as? [String: Any],
                        let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double else { return false }
                  return width > 100 && height > 100
              }),
              (front[kCGWindowNumber as String] as? UInt32) == windowID else {
            throw bridgeError("The mirrored phone window changed. Input stopped.")
        }
    }
    @available(macOS 14.0, *)
    private func capturePrompt(_ mirror: NSRunningApplication, expectedWindowID: CGWindowID?, expectedFilled: Int) async throws -> CapturedPrompt {
        try checkAuthorization()
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        try checkAuthorization()
        let candidates = content.windows.filter { $0.owningApplication?.processID == mirror.processIdentifier && $0.frame.width > 150 && $0.frame.height > $0.frame.width }
        guard let window = candidates.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }),
              expectedWindowID == nil || expectedWindowID == window.windowID else {
            throw bridgeError("No unchanged portrait iPhone Mirroring window is visible. Nothing further was typed.")
        }
        try assertTarget(mirror, windowID: window.windowID)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width * 2); configuration.height = Int(window.frame.height * 2)
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration)
        try checkAuthorization()
        let slots = try await Self.analyzeCapturedFrame(image, expectedFilled: expectedFilled)
        try checkAuthorization()
        try assertTarget(mirror, windowID: window.windowID)
        return CapturedPrompt(windowID: window.windowID, width: image.width, height: image.height, slots: slots)
    }
    // CGImage is immutable. Only its retained pixel image crosses queues; no
    // AppKit/AX objects or authorization state leave the main actor.
    private struct CapturedImage: @unchecked Sendable { let image: CGImage }
    nonisolated private static func analyzeCapturedFrame(_ image: CGImage, expectedFilled: Int) async throws -> SlotLayout {
        let captured = CapturedImage(image: image)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let result = Result { try autoreleasepool { try analyzeFrame(captured.image, expectedFilled: expectedFilled) } }
                continuation.resume(with: result)
            }
        }
    }
    enum TextRecognitionMode { case standard, compatibility }
    struct RecognizedText {
        let text: String
        let confidence: Float
        let boundingBox: CGRect
    }
    /// Give Vision an owned, conventional bitmap rather than a capture-backed,
    /// potentially extended-range image. Keep coordinates identical for slot checks.
    nonisolated static func recognitionImage(_ image: CGImage) throws -> CGImage {
        guard image.width > 0, image.height > 0, image.width <= 5000, image.height <= 10000,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height,
                  bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw NSError(domain: "HarmonyPhone", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not prepare the phone image for reading. No further input was sent."])
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let result = context.makeImage() else {
            throw NSError(domain: "HarmonyPhone", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not read the phone image. No further input was sent."])
        }
        return result
    }
    nonisolated static func recognizeText(in image: CGImage, mode: TextRecognitionMode) throws -> [RecognizedText] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]; request.usesLanguageCorrection = false
        if mode == .compatibility {
            // Keep the accurate recognizer and its confidence checks. Explicit
            // CPU placement avoids depending on an unavailable accelerator.
            if #available(macOS 14.0, *) {
                for (stage, devices) in try request.supportedComputeStageDevices {
                    guard let cpu = devices.first(where: { if case .cpu = $0 { return true }; return false }) else {
                        throw NSError(domain: "HarmonyPhone", code: 1)
                    }
                    request.setComputeDevice(cpu, for: stage)
                }
            } else { request.usesCPUOnly = true }
        }
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return RecognizedText(text: candidate.string.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " "),
                                  confidence: candidate.confidence, boundingBox: observation.boundingBox)
        }
    }
    nonisolated static func analyzeFrame(_ captured: CGImage, expectedFilled: Int,
        recognize: (CGImage, TextRecognitionMode) throws -> [RecognizedText] = recognizeText) throws -> SlotLayout {
        try Task.checkCancellation()
        let image = try recognitionImage(captured)
        let observations: [RecognizedText]
        do { observations = try recognize(image, .standard) }
        catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            do { observations = try recognize(image, .compatibility) }
            catch is CancellationError { throw CancellationError() }
            catch {
                throw NSError(domain: "HarmonyPhone", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "macOS could not read the phone screen. Keep iPhone Mirroring on Enter Screen Time Passcode, clear any filled dots, then try again. No further digits were sent."])
            }
        }
        try Task.checkCancellation()
        let texts = observations.map(\.text)
        let labels = observations.filter { $0.text == "enter screen time passcode" && $0.confidence >= 0.8 }
        guard labels.count == 1, Self.isUnlockScreen(texts),
              let label = labels.first else {
            throw NSError(domain: "HarmonyPhone", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not verify the Screen Time passcode screen. Open the passcode prompt in Settings or the app's time request, then try again. No further input was sent."])
        }
        let box = label.boundingBox
        let pixels = CGRect(x: box.minX * CGFloat(image.width), y: (1 - box.maxY) * CGFloat(image.height),
                            width: box.width * CGFloat(image.width), height: box.height * CGFloat(image.height))
        guard let slots = Self.passcodeSlots(in: image, below: pixels, expectedFilled: expectedFilled) else {
            throw NSError(domain: "HarmonyPhone", code: 1, userInfo: [NSLocalizedDescriptionKey: "The four passcode indicators were not in the expected state. Clear the field and try again; no further input was sent."])
        }
        return slots
    }
    static func keyCode(for digit: UInt8) -> CGKeyCode? {
        let keys: [CGKeyCode] = [29, 18, 19, 20, 21, 23, 22, 26, 28, 25]
        guard digit >= 48 && digit <= 57 else { return nil }
        return keys[Int(digit - 48)]
    }
    @available(macOS 14.0, *)
    private func typeIfScreenTime(_ pin: String, mirror: NSRunningApplication) async throws {
        guard pin.utf8.count == 4, pin.utf8.allSatisfy({ Self.keyCode(for: $0) != nil }) else { throw bridgeError("Invalid saved phone code.") }
        var baseline: CapturedPrompt?
        for (index, digit) in pin.utf8.enumerated() {
            try checkAuthorization()
            let state = try await capturePrompt(mirror, expectedWindowID: baseline?.windowID, expectedFilled: index)
            if let baseline = baseline {
                guard baseline.width == state.width, baseline.height == state.height,
                      zip(baseline.slots.centers, state.slots.centers).allSatisfy({ hypot($0.0.x - $0.1.x, $0.0.y - $0.1.y) < baseline.slots.diameter * 0.25 }) else {
                    throw bridgeError("The phone view moved or resized. Input stopped.")
                }
            } else { baseline = state }
            try checkAuthorization()
            try assertTarget(mirror, windowID: state.windowID)
            let modifiers = CGEventSource.flagsState(.combinedSessionState)
            guard modifiers.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty else {
                throw bridgeError("Release modifier keys before phone entry. Input stopped.")
            }
            guard let key = Self.keyCode(for: digit),
                  let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false) else { throw bridgeError("Could not create keyboard input.") }
            down.flags = []; up.flags = []
            var character = UniChar(digit)
            down.keyboardSetUnicodeString(stringLength: 1, unicodeString: &character)
            up.keyboardSetUnicodeString(stringLength: 1, unicodeString: &character)
            down.postToPid(mirror.processIdentifier); up.postToPid(mirror.processIdentifier)
            try await Task.sleep(nanoseconds: 180_000_000)
        }
        // Do not claim acceptance merely because four events were sent. The user
        // verifies the resulting iPhone screen; no automatic retries are performed.
    }
    private func bridgeError(_ message: String) -> NSError {
        NSError(domain: "HarmonyPhone", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
