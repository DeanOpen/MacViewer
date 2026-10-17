import Foundation
import LocalAuthentication
import Security
import Testing
@testable import MacViewer

@MainActor
struct PartnerCredentialStoreTests {
    @Test("Credentials replace in place and removal stays within this app's local namespace")
    func credentialLifecycle() throws {
        let backend = MemoryKeychain()
        let service = "MacViewer.tests.\(UUID().uuidString)"
        let store = KeychainPartnerCredentialStore(service: service, operations: backend.operations)
        backend.items[.init(service: "unrelated.application", account: "123456789", synchronized: false)] = Data("foreign".utf8)
        backend.items[.init(service: service, account: "123456789", synchronized: true)] = Data("synced".utf8)
        #expect(try store.password(forID: "123456789") == nil)
        try store.store(password: "first", forID: "123 456-789")
        #expect(try store.password(forID: "123456789") == "first")
        try store.store(password: "密碼👋|second", forID: "123456789")
        #expect(try store.password(forID: "123 456 789") == "密碼👋|second")
        try store.store(password: "other", forID: "987654321")
        try store.remove(forID: "987654321")
        try store.remove(forID: "987654321")
        #expect(try store.password(forID: "987654321") == nil)
        try store.removeAll()
        try store.removeAll()
        #expect(try store.password(forID: "123456789") == nil)
        #expect(backend.items.count == 2)
        #expect(backend.items[.init(service: "unrelated.application", account: "123456789", synchronized: false)]
                == Data("foreign".utf8))
        #expect(backend.items[.init(service: service, account: "123456789", synchronized: true)] == Data("synced".utf8))
        for query in backend.queries {
            #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
            #expect(query[kSecAttrService as String] as? String == service)
            #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
            let context = try #require(query[kSecUseAuthenticationContext as String] as? LAContext)
            #expect(context.interactionNotAllowed)
        }
    }

    @Test("Locked Keychain errors preserve saved secrets and never become a missing password")
    func deniedAccess() throws {
        let backend = MemoryKeychain()
        let store = KeychainPartnerCredentialStore(service: "MacViewer.tests.\(UUID().uuidString)",
                                                   operations: backend.operations)
        try store.store(password: "retained secret", forID: "123456789")
        backend.failure = errSecInteractionNotAllowed
        #expect(throws: KeychainPartnerCredentialStore.Error.keychain(errSecInteractionNotAllowed)) {
            try store.password(forID: "123456789")
        }
        #expect(throws: KeychainPartnerCredentialStore.Error.keychain(errSecInteractionNotAllowed)) {
            try store.store(password: "replacement", forID: "123456789")
        }
        backend.failure = nil
        #expect(try store.password(forID: "123456789") == "retained secret")
    }

    @Test("Invalid identifiers and corrupt secrets cannot become broad Keychain queries or autofill")
    func invalidData() throws {
        let backend = MemoryKeychain()
        let service = "MacViewer.tests.\(UUID().uuidString)"
        let store = KeychainPartnerCredentialStore(service: service, operations: backend.operations)
        #expect(throws: KeychainPartnerCredentialStore.Error.invalidPartnerID) { try store.remove(forID: "") }
        #expect(throws: KeychainPartnerCredentialStore.Error.invalidPartnerID) { try store.password(forID: "../123") }
        #expect(throws: KeychainPartnerCredentialStore.Error.emptyPassword) { try store.store(password: "", forID: "123") }
        #expect(backend.queries.isEmpty)
        backend.items[.init(service: service, account: "123", synchronized: false)] = Data([0xFF, 0xFE, 0xFF])
        #expect(throws: KeychainPartnerCredentialStore.Error.invalidStoredPassword) { try store.password(forID: "123") }
    }
}

/// Security API test double only: no SecItem function is called by these tests.
@MainActor
private final class MemoryKeychain {
    struct Key: Hashable {
        let service: String
        let account: String
        let synchronized: Bool
    }
    typealias Query = KeychainPartnerCredentialStore.Operations.Query
    var items: [Key: Data] = [:]
    var queries: [Query] = []
    var failure: OSStatus?

    var operations: KeychainPartnerCredentialStore.Operations {
        .init(copy: { [self] query in
            queries.append(query)
            if let failure { return (failure, nil) }
            guard let key = matching(query).first, let data = items[key] else { return (errSecItemNotFound, nil) }
            return (errSecSuccess, data as CFData)
        }, add: { [self] query in
            queries.append(query)
            if let failure { return failure }
            guard let service = query[kSecAttrService as String] as? String,
                  let account = query[kSecAttrAccount as String] as? String,
                  let data = query[kSecValueData as String] as? Data else { return errSecParam }
            let key = Key(service: service, account: account,
                          synchronized: query[kSecAttrSynchronizable as String] as? Bool ?? false)
            guard items[key] == nil else { return errSecDuplicateItem }
            items[key] = data
            return errSecSuccess
        }, update: { [self] query, changes in
            queries.append(query)
            if let failure { return failure }
            let keys = matching(query)
            guard !keys.isEmpty else { return errSecItemNotFound }
            guard let data = changes[kSecValueData as String] as? Data else { return errSecParam }
            for key in keys { items[key] = data }
            return errSecSuccess
        }, delete: { [self] query in
            queries.append(query)
            if let failure { return failure }
            let keys = matching(query)
            for key in keys { items.removeValue(forKey: key) }
            return keys.isEmpty ? errSecItemNotFound : errSecSuccess
        })
    }

    private func matching(_ query: Query) -> [Key] {
        let service = query[kSecAttrService as String] as? String
        let account = query[kSecAttrAccount as String] as? String
        let synchronized = query[kSecAttrSynchronizable as String] as? Bool
        return items.keys.filter {
            $0.service == service && (account == nil || $0.account == account)
                && (synchronized == nil || $0.synchronized == synchronized)
        }
    }
}
