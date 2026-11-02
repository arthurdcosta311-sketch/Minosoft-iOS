import Foundation
import Security

/// The account signed in on this device. The tokens live in the Keychain, not
/// in UserDefaults: a refresh token is a password to the player's Minecraft
/// account.
@MainActor
final class AccountStore: ObservableObject {
    static let shared = AccountStore()

    @Published private(set) var signedIn: SignedInAccount?

    private let service = "de.bixilon.minosoft.account"
    private let key = "microsoft"

    init() {
        signedIn = Self.load(service: service, key: key)
    }

    func update(_ account: SignedInAccount) {
        signedIn = account
        Self.save(account, service: service, key: key)
    }

    /// Stores a refreshed `Account`, which carries the same profile.
    func update(_ account: Account) {
        guard let signedIn = account.signedIn else { return }
        update(signedIn)
    }

    func signOut() {
        signedIn = nil
        Self.delete(service: service, key: key)
    }

    // MARK: Keychain

    private static func load(service: String, key: String) -> SignedInAccount? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let account = try? JSONDecoder().decode(SignedInAccount.self, from: data) else {
            return nil
        }
        return account
    }

    private static func save(_ value: SignedInAccount, service: String, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            var insert = query
            insert.merge(attributes) { _, new in new }
            SecItemAdd(insert as CFDictionary, nil)
        }
    }

    private static func delete(service: String, key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
