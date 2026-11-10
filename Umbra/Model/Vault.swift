import Foundation
import Security
import UmbraCore

/// Encrypted on-disk state. A random 256-bit key lives in the Keychain (this device only);
/// the state is sealed with ChaCha20-Poly1305 and written with complete file protection.
/// Deleting the key makes the file unreadable — that is the panic wipe.
enum Vault {
    enum LoadResult {
        case empty
        case loaded(VaultState)
        /// A vault exists but cannot be opened. Never treat this as "first launch": that would
        /// invite the user to create a new identity over the top of the old one.
        case unreadable(String)
    }

    private static let service = "umbra.vault"
    private static let account = "vault-key"

    private static var fileURL: URL {
        directory.appendingPathComponent("state.vault")
    }

    static var directory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Umbra", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func load() -> LoadResult {
        guard let sealed = try? Data(contentsOf: fileURL) else { return .empty }
        guard let key = readKey() else { return .unreadable("The vault key is missing from the Keychain.") }
        guard let box = try? ChaChaPoly.SealedBox(combined: sealed), let plain = try? ChaChaPoly.open(box, using: key) else {
            return .unreadable("The vault could not be decrypted.")
        }
        guard let state = try? JSONDecoder().decode(VaultState.self, from: plain) else {
            return .unreadable("The vault format is not recognised.")
        }
        return .loaded(state)
    }

    static func save(_ state: VaultState) throws {
        let key = try readKey() ?? createKey()
        let sealed = try ChaChaPoly.seal(try JSONEncoder().encode(state), using: key).combined
        #if os(iOS) || os(visionOS)
        try sealed.write(to: fileURL, options: [.atomic, .completeFileProtection])
        #else
        try sealed.write(to: fileURL, options: .atomic)
        #endif
    }

    static func wipe() {
        for query in queries { SecItemDelete(query as CFDictionary) }
        for url in [fileURL, directory.appendingPathComponent("host-store.sealed")] {
            if let handle = try? FileHandle(forWritingTo: url) {
                // Overwrite before unlinking; the key is already gone so this is belt and braces.
                let size = (try? handle.seekToEnd()) ?? 0
                try? handle.seek(toOffset: 0)
                try? handle.write(contentsOf: Data.random(Int(size)))
                try? handle.close()
            }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Data-protection keychain first; the legacy macOS keychain as a fallback for builds signed
    /// without a team (which get errSecMissingEntitlement from the former).
    private static var queries: [[String: Any]] {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        var modern = base
        modern[kSecUseDataProtectionKeychain as String] = true
        return [modern, base]
    }

    private static func readKey() -> SymmetricKey? {
        for var query in queries {
            query[kSecReturnData as String] = true
            var out: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data {
                return SymmetricKey(data: data)
            }
        }
        return nil
    }

    private static func createKey() throws -> SymmetricKey {
        let data = Data.random(32)
        var lastStatus = errSecSuccess
        for var query in queries {
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            lastStatus = SecItemAdd(query as CFDictionary, nil)
            if lastStatus == errSecSuccess { return SymmetricKey(data: data) }
        }
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(lastStatus))
    }
}
