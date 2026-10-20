import CryptoKit
import Foundation
import Security

/// Encrypts everything Clipline writes to disk.
///
/// The key is 256 random bits kept in the login keychain, readable only by this signed app,
/// so the support folder on its own is useless: copying clipline.db, the blobs or the
/// thumbnails off the disk yields AES-GCM ciphertext and nothing else. History therefore
/// never sits on disk in plain text, which matters for a clipboard that sees passwords,
/// keys and seed phrases.
final class ClipVault {
    static let shared = ClipVault()

    /// Marks sealed file contents. Anything without it is a file from a build before
    /// encryption, which the store migrates on launch.
    private static let fileMagic = Data("CLV1".utf8)
    /// Marks sealed text columns, for the same reason.
    private static let textPrefix = "clv1:"

    private static let keychainService = "com.joymadhu.Clipline.vault"
    private static let keychainAccount = "storage-key"

    private let key: SymmetricKey
    /// True when no key existed and a new one was made. Anything sealed before that point
    /// can never be read again, so the store throws it away.
    let isNewKey: Bool

    private init() {
        if let stored = Self.readKey() {
            key = SymmetricKey(data: stored)
            isNewKey = false
        } else {
            let fresh = SymmetricKey(size: .bits256)
            let data = fresh.withUnsafeBytes { Data($0) }
            if !Self.storeKey(data) {
                NSLog("Clipline: could not save the storage key to the keychain")
            }
            key = fresh
            isNewKey = true
        }
    }

    // MARK: Data

    func seal(_ data: Data) -> Data? {
        guard let box = try? AES.GCM.seal(data, using: key), let combined = box.combined else { return nil }
        return Self.fileMagic + combined
    }

    /// Opens sealed data. Data from a build before encryption passes through unchanged so a
    /// half finished migration never loses an entry.
    func open(_ data: Data) -> Data? {
        guard Self.isSealed(data) else { return data }
        guard let box = try? AES.GCM.SealedBox(combined: data.dropFirst(Self.fileMagic.count)) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }

    static func isSealed(_ data: Data) -> Bool {
        data.count > fileMagic.count && data.prefix(fileMagic.count) == fileMagic
    }

    // MARK: Text

    func sealText(_ value: String) -> String {
        // Empty stays empty so "no label" still reads as no label. A failed seal stores
        // nothing rather than falling back to plain text.
        guard !value.isEmpty else { return "" }
        guard let sealed = seal(Data(value.utf8)) else { return "" }
        return Self.textPrefix + sealed.dropFirst(Self.fileMagic.count).base64EncodedString()
    }

    func openText(_ value: String) -> String {
        guard Self.isSealedText(value) else { return value }
        guard let combined = Data(base64Encoded: String(value.dropFirst(Self.textPrefix.count))),
              let plain = open(Self.fileMagic + combined) else { return "" }
        return String(decoding: plain, as: UTF8.self)
    }

    static func isSealedText(_ value: String) -> Bool {
        value.hasPrefix(textPrefix)
    }

    /// Keyed digest used to fold duplicates. A bare SHA256 of a short clip can be reversed
    /// by guessing, so the stored digest is an HMAC under the vault key instead.
    func tag(_ digest: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(digest.utf8), using: key)
        return "h1:" + mac.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Keychain

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
    }

    private static func readKey() -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, data.count == 32 else { return nil }
        return data
    }

    private static func storeKey(_ data: Data) -> Bool {
        SecItemDelete(baseQuery() as CFDictionary)
        var query = baseQuery()
        query[kSecValueData as String] = data
        query[kSecAttrLabel as String] = "Clipline storage key"
        // Never leaves this Mac: not synced to iCloud Keychain, not restored to another
        // machine from a backup.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        query[kSecAttrSynchronizable as String] = false
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }
}
