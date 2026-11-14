import Foundation
import Security

/// Stores the FACEIT API key so that both the app and the widget extension can read it.
///
/// 1. Preferred: Data Protection keychain item in the App Group access group
///    (works when the build carries a provisioning profile — iOS, or macOS with a profile).
/// 2. Fallback: a 0600 file inside the App Group container. On macOS the group container is
///    sandbox-protected (only apps of the same team and group can open it). Used when the keychain
///    reports `errSecMissingEntitlement` (-34018), e.g. a macOS build signed without a profile.
///
/// The key is never logged and never written to UserDefaults.
public enum APIKeyStore {
    public enum Backend: String, Sendable { case keychain = "Keychain", groupFile = "Файл в App Group", none = "нет" }

    static let service = "com.k33ssa.simplefaceit.api"
    static let account = "faceit-data-api-key"

    static var fileURL: URL { AppGroup.dataDirectory.appendingPathComponent(".apikey") }

    public static func load() -> String? {
        if let k = keychainRead(), !k.isEmpty { return k }
        if let d = try? Data(contentsOf: fileURL), let k = String(data: d, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty { return k }
        return nil
    }

    public static var backend: Backend {
        if keychainRead() != nil { return .keychain }
        if FileManager.default.fileExists(atPath: fileURL.path) { return .groupFile }
        return .none
    }

    @discardableResult
    public static func save(_ key: String) -> Backend {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        delete()
        guard !key.isEmpty else { return .none }
        if keychainWrite(key) { return .keychain }
        let url = fileURL
        FileManager.default.createFile(atPath: url.path, contents: Data(key.utf8), attributes: [.posixPermissions: 0o600])
        return .groupFile
    }

    public static func delete() {
        SecItemDelete(baseQuery() as CFDictionary)
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: Keychain

    private static func baseQuery() -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let group = AppGroup.identifier, AppGroup.isShared { q[kSecAttrAccessGroup as String] = group }
        return q
    }

    private static func keychainRead() -> String? {
        var q = baseQuery()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    private static func keychainWrite(_ key: String) -> Bool {
        var q = baseQuery()
        q[kSecValueData as String] = Data(key.utf8)
        // Widgets refresh while the device is locked: allow after first unlock.
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }
}
