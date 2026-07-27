import Diagnostics
import Foundation
import RDPDomain
import Security

public struct CredentialMaterial: Codable, Equatable, Sendable {
    public static let maximumUsernameBytes = 1_024
    public static let maximumDomainBytes = 1_024
    public static let maximumPasswordBytes = 16 * 1024

    public var username: String
    public var domain: String
    public var password: String

    public init(username: String, domain: String = "", password: String) {
        self.username = username
        self.domain = domain
        self.password = password
    }

    public func validated() throws -> CredentialMaterial {
        guard !username.isEmpty, !password.isEmpty,
              username.utf8.count <= Self.maximumUsernameBytes,
              domain.utf8.count <= Self.maximumDomainBytes,
              password.utf8.count <= Self.maximumPasswordBytes,
              !username.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !domain.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !password.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw CredentialStoreError.invalidMaterial
        }
        return self
    }
}

public protocol CredentialStoring: Sendable {
    func save(_ material: CredentialMaterial, reference: CredentialReference) throws
    func load(reference: CredentialReference) throws -> CredentialMaterial?
    func delete(reference: CredentialReference) throws
}

public enum CredentialStoreError: Error, LocalizedError, Sendable {
    case encoding
    case invalidMaterial
    case unexpectedStatus(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .encoding: return "The credential could not be encoded."
        case .invalidMaterial: return "The credential contains unsupported characters or exceeds the supported size."
        case let .unexpectedStatus(status):
            return SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)."
        }
    }
}

public final class KeychainCredentialStore: CredentialStoring, @unchecked Sendable {
    private let servicePrefix: String
    private let lock = NSLock()

    public init(servicePrefix: String = "com.example.RemoteDesktop.credentials") {
        self.servicePrefix = servicePrefix
    }

    public func save(_ material: CredentialMaterial, reference: CredentialReference) throws {
        let material = try material.validated()
        let data: Data
        do { data = try JSONEncoder().encode(material) }
        catch { throw CredentialStoreError.encoding }
        let query = baseQuery(reference)
        lock.lock(); defer { lock.unlock() }
        let update = [kSecValueData as String: data] as CFDictionary
        let status = SecItemUpdate(query as CFDictionary, update)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw CredentialStoreError.unexpectedStatus(status) }
        var insertion = query
        insertion[kSecValueData as String] = data
        insertion[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let addStatus = SecItemAdd(insertion as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw CredentialStoreError.unexpectedStatus(addStatus) }
    }

    public func load(reference: CredentialReference) throws -> CredentialMaterial? {
        var query = baseQuery(reference)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        lock.lock(); defer { lock.unlock() }
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw CredentialStoreError.unexpectedStatus(status)
        }
        do { return try JSONDecoder().decode(CredentialMaterial.self, from: data).validated() }
        catch { throw CredentialStoreError.encoding }
    }

    public func delete(reference: CredentialReference) throws {
        lock.lock(); defer { lock.unlock() }
        let status = SecItemDelete(baseQuery(reference) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.unexpectedStatus(status)
        }
    }

    private func baseQuery(_ reference: CredentialReference) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "\(servicePrefix).\(reference.kind.rawValue)",
            kSecAttrAccount as String: reference.id.uuidString,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
    }
}
