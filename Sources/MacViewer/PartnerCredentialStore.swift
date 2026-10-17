import Foundation
import LocalAuthentication
import Security

@MainActor
protocol PartnerCredentialStore {
    func password(forID identifier: String) throws -> String?
    func store(password: String, forID identifier: String) throws
    func remove(forID identifier: String) throws
    func removeAll() throws
}

/// Partner secrets remain in this Mac's Keychain. The connection model owns
/// the remember preference and must save only after successful authentication.
@MainActor
final class KeychainPartnerCredentialStore: PartnerCredentialStore {
    enum Error: Swift.Error, Equatable, LocalizedError {
        case invalidPartnerID, emptyPassword, passwordTooLong, invalidStoredPassword
        case keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .invalidPartnerID: return "A valid partner ID is required to access a saved password."
            case .emptyPassword: return "An empty partner password cannot be saved."
            case .passwordTooLong: return "The partner password exceeds the Keychain storage limit."
            case .invalidStoredPassword: return "The saved partner password could not be read. Enter it again."
            case let .keychain(status):
                if status == errSecInteractionNotAllowed || status == errSecAuthFailed {
                    return "The saved password is unavailable while Keychain access is locked or restricted."
                }
                let reason = SecCopyErrorMessageString(status, nil) as String?
                return reason.map { "Keychain could not save or read the password: \($0)" }
                    ?? "Keychain could not save or read the password (\(status))."
            }
        }
    }

    /// Injectable Security boundary for tests. The production default never
    /// falls back to UserDefaults, files, synchronization or an in-memory save.
    struct Operations {
        typealias Query = [String: Any]
        var copy: (Query) -> (OSStatus, CFTypeRef?)
        var add: (Query) -> OSStatus
        var update: (Query, Query) -> OSStatus
        var delete: (Query) -> OSStatus

        static var system: Self {
            Self(copy: { query in
                var result: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &result)
                return (status, result)
            }, add: { SecItemAdd($0 as CFDictionary, nil) },
                 update: { SecItemUpdate($0 as CFDictionary, $1 as CFDictionary) },
                 delete: { SecItemDelete($0 as CFDictionary) })
        }
    }

    static let service = "dev.macviewer.partner"
    private let serviceName: String
    private let operations: Operations
    private static let maximumPasswordBytes = 64 * 1024

    init() {
        serviceName = Self.service
        operations = .system
    }

    /// Tests supply an in-memory backend and a unique namespace; they never
    /// need to read or write the user's real default Keychain.
    init(service: String, operations: Operations) {
        precondition(!service.isEmpty)
        serviceName = service
        self.operations = operations
    }

    func password(forID identifier: String) throws -> String? {
        var query = try itemQuery(identifier: identifier)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, result) = operations.copy(query)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data, data.count <= Self.maximumPasswordBytes,
              let password = String(data: data, encoding: .utf8), !password.isEmpty else {
            throw Error.invalidStoredPassword
        }
        return password
    }

    func store(password: String, forID identifier: String) throws {
        let query = try itemQuery(identifier: identifier)
        let data = Data(password.utf8)
        guard !data.isEmpty else { throw Error.emptyPassword }
        guard data.count <= Self.maximumPasswordBytes else { throw Error.passwordTooLong }
        let changes: Operations.Query = [kSecValueData as String: data]
        let status = operations.update(query, changes)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw Error.keychain(status) }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "MacViewer partner password"
        let added = operations.add(item)
        if added == errSecDuplicateItem {
            // Another writer can create the same item after our update query.
            // Update it in place rather than deleting a valid existing secret.
            try check(operations.update(query, changes))
        } else { try check(added) }
    }

    func remove(forID identifier: String) throws {
        let status = operations.delete(try itemQuery(identifier: identifier))
        if status != errSecItemNotFound { try check(status) }
    }

    func removeAll() throws {
        // Deliberately service-scoped and non-synchronizable: this cannot clear
        // unrelated Keychain items or copies synchronized to other devices.
        let status = operations.delete(baseQuery())
        if status != errSecItemNotFound { try check(status) }
    }

    private func itemQuery(identifier: String) throws -> Operations.Query {
        let account = identifier.filter { !$0.isWhitespace && $0 != "-" }
        guard !account.isEmpty, account.utf8.count <= 64,
              account.utf8.allSatisfy({ (48...57).contains($0) }) else { throw Error.invalidPartnerID }
        var query = baseQuery()
        query[kSecAttrAccount as String] = account
        return query
    }

    private func baseQuery() -> Operations.Query {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrSynchronizable as String: false,
            // Current SDK replacement for kSecUseAuthenticationUIFail. When
            // interaction is required, return an error instead of prompting.
            kSecUseAuthenticationContext as String: context,
        ]
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw Error.keychain(status) }
    }
}
