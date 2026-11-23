import AppKit
import Security

/// Optional, local Keychain enrollment for the phone-entry prompt.
@MainActor enum PhoneDailyClipboard {
    private static let service = "local.harmony.focus.daily-phone-paste"
    private static let account = "Harmony recovery password"

    private static var key: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func remember(_ password: String, expectedDigest: String) throws {
        guard !password.isEmpty, AppSetup.digest(password) == expectedDigest else {
            throw NSError(domain: "HarmonyDailyPaste", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "The supplied password did not match Harmony."])
        }
        let attributes: [String: Any] = [
            kSecValueData as String: Data(password.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrLabel as String: "Harmony daily phone paste"
        ]
        var result = SecItemAdd(key.merging(attributes) { _, value in value } as CFDictionary, nil)
        if result == errSecDuplicateItem {
            result = SecItemUpdate(key as CFDictionary, attributes as CFDictionary)
        }
        guard result == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(result)) }
        UserDefaults.standard.set(true, forKey: "dailyPhonePasteEnrolled")
    }

    static func prepareIfAvailable(expectedDigest: String) -> Int? {
        guard PhonePastePolicy.isAvailable(), UserDefaults.standard.bool(forKey: "dailyPhonePasteEnrolled") else { return nil }
        var query = key
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let password = String(data: data, encoding: .utf8),
              AppSetup.digest(password) == expectedDigest else { return nil }
        return publish(password, to: .general)
    }

    static func publish(_ password: String, to board: NSPasteboard) -> Int? {
        let item = NSPasteboardItem()
        guard item.setString(password, forType: .string),
              item.setData(Data(), forType: .init("org.nspasteboard.ConcealedType")),
              item.setData(Data(), forType: .init("org.nspasteboard.TransientType")) else { return nil }
        board.prepareForNewContents(with: .currentHostOnly)
        guard board.writeObjects([item]) else { return nil }
        let version = board.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) {
            clearIfOwned(version, on: board)
        }
        return version
    }

    static func clearIfOwned(_ version: Int, on board: NSPasteboard = .general) {
        guard board.changeCount == version else { return }
        board.clearContents()
    }
}
