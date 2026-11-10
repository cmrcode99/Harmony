import Cocoa

@main struct NativeInterfaceTests {
    static func main() {
        for (input, expected) in [(Double.nan, 70.0), (.infinity, 70), (-10, 0), (110, 100), (37, 37)] {
            precondition(HarmonyInterface.volume(input) == expected, "Invalid volume could break the complete player update")
        }
        let main = NSRect(x: 0, y: 40, width: 1440, height: 860)
        let left = NSRect(x: -1920, y: 0, width: 1920, height: 1080)
        func fit(_ frame: NSRect, screens: [NSRect] = [main, left]) -> NSRect {
            HarmonyInterface.videoFrame(frame, visibleFrames: screens, fallback: main)
        }
        let unchanged = NSRect(x: 12, y: 600, width: 320, height: 180)
        precondition(fit(unchanged) == unchanged, "Ordinary placement moved unnecessarily")
        let enlargedAtEdge = fit(NSRect(x: 1350, y: -100, width: 480, height: 270))
        precondition(main.contains(enlargedAtEdge), "Size preset left controls outside the display")
        let onLeft = fit(NSRect(x: -1850, y: 400, width: 320, height: 180))
        precondition(left.contains(onLeft), "Negative-origin display was lost")
        precondition(main.contains(fit(onLeft, screens: [main])), "Disconnected display was not rescued")
        let huge = fit(NSRect(x: 100, y: 100, width: 3000, height: 1687.5), screens: [main])
        precondition(main.contains(huge) && abs(huge.width / huge.height - 16.0 / 9) < 0.001,
                     "Small display rescue lost aspect ratio or reachable controls")
        let noScreens = HarmonyInterface.videoFrame(unchanged, visibleFrames: [], fallback: nil)
        precondition(noScreens == unchanged, "Empty display inventory changed geometry")
        print("PASS native interface: invalid saved volume, edge resizing, negative-origin/disconnected displays, aspect ratio")
    }
}
